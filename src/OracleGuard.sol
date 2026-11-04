// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title OracleGuard — red de seguridad de precios para el Router de DUOX
/// @notice Lee Chainlink (BTC/USD, ETH/USD, WBTC/BTC, stablecoins y Sequencer Uptime de Arbitrum) y
///         revierte si algún dato es inválido o si un swap rindió peor que el oráculo más allá del margen.
/// @dev El núcleo (DuoxVault) NO usa este contrato. Si falla, solo se detiene el Router y la salida
///      In-Kind sigue abierta. Ver Especificaciones Técnicas, sección 4.
///      Regla de permisos: endurecer = guardián (inmediato); relajar = administrador/Timelock (con espera).
contract OracleGuard is AccessControlDefaultAdminRules {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Safe multisig: puede revocar guardianes al instante.
    bytes32 public constant SAFE_ROLE = keccak256("SAFE_ROLE");

    bytes32 public constant BTC_USD = keccak256("BTC_USD");
    bytes32 public constant ETH_USD = keccak256("ETH_USD");
    bytes32 public constant WBTC_BTC = keccak256("WBTC_BTC");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    // ─────────────── Techos y pisos fijos en código (sección 4.9) ───────────────
    uint256 public constant MAX_MARGIN_BPS = 300; // 3%
    uint256 public constant MAX_STALENESS_CAP = 26 hours;
    uint256 public constant MIN_GRACE_PERIOD = 30 minutes;
    uint256 public constant MIN_WRAPPER_THRESHOLD = 0.95e18;
    uint256 public constant MIN_STABLE_PRICE_FLOOR = 0.95e18;

    /// @notice Feed a configurar en el despliegue.
    struct FeedInit {
        bytes32 key;
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint96 minPrice;
        uint96 maxPrice;
    }

    /// @notice Stablecoin a configurar en el despliegue.
    struct StableInit {
        address token;
        uint8 decimals;
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint96 minPrice;
        uint96 maxPrice;
    }

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxStaleness; // segundos
        uint8 decimals; // decimales del feed
        uint96 minPrice; // rango de cordura, normalizado a 18 decimales
        uint96 maxPrice;
    }

    /// @notice Decimales del activo BTC (WBTC = 8) y ETH (WETH = 18).
    uint8 public immutable BTC_DECIMALS;
    uint8 public immutable ETH_DECIMALS;

    AggregatorV3Interface public sequencerFeed;
    uint256 public gracePeriod;
    uint256 public marginBps;
    uint256 public wrapperBlockThreshold; // por debajo: compras bloqueadas
    uint256 public wrapperAlertThreshold; // solo informativo para monitoreo e interfaz
    uint256 public minStablePrice;

    /// @notice clave → configuración del feed. Para stablecoins la clave es stableKey(token).
    mapping(bytes32 => FeedConfig) internal _feeds;
    /// @notice decimales de cada stablecoin configurada (0 = no configurada).
    mapping(address => uint8) public stableDecimals;

    event FeedSet(bytes32 indexed key, address feed, uint32 maxStaleness, uint96 minPrice, uint96 maxPrice);
    event StableSet(address indexed token, uint8 decimals);
    event SequencerFeedSet(address indexed feed);
    event ParamChanged(bytes32 indexed param, uint256 oldValue, uint256 newValue);

    error ZeroAddress();
    error FeedNotSet(bytes32 key);
    error FeedCallFailed(bytes32 key);
    error InvalidPrice(bytes32 key);
    error StalePrice(bytes32 key);
    error PriceOutOfRange(bytes32 key);
    error SequencerDown();
    error SequencerNotInitialized();
    error GracePeriodNotOver();
    error StableNotSupported(address token);
    error StablePriceTooLow(address token);
    error WrapperDepegged();
    error ExecutionWorseThanOracle(uint256 valueIn, uint256 valueOut);
    error NotTighter();
    error NotLooser();
    error OutOfBounds();
    error InvalidFeed();

    constructor(
        address admin,
        uint48 adminTransferDelay,
        address safe,
        address guardian,
        uint8 btcDecimals,
        uint8 ethDecimals,
        AggregatorV3Interface sequencerFeed_,
        FeedInit[] memory initFeeds,
        StableInit[] memory initStables
    ) AccessControlDefaultAdminRules(adminTransferDelay, admin) {
        if (safe == address(0) || guardian == address(0) || address(sequencerFeed_) == address(0)) {
            revert ZeroAddress();
        }
        BTC_DECIMALS = btcDecimals;
        ETH_DECIMALS = ethDecimals;
        sequencerFeed = sequencerFeed_;

        gracePeriod = 1 hours;
        marginBps = 100; // 1%
        wrapperBlockThreshold = 0.98e18;
        wrapperAlertThreshold = 0.99e18;
        minStablePrice = 0.98e18;

        _grantRole(SAFE_ROLE, safe);
        _grantRole(GUARDIAN_ROLE, safe);
        _grantRole(GUARDIAN_ROLE, guardian);

        // Configuración inicial en el mismo despliegue: así quien despliega nunca necesita permisos.
        for (uint256 i; i < initFeeds.length; i++) {
            FeedInit memory f = initFeeds[i];
            _setFeed(f.key, f.feed, f.maxStaleness, f.minPrice, f.maxPrice);
        }
        for (uint256 i; i < initStables.length; i++) {
            StableInit memory st = initStables[i];
            _setStable(st.token, st.decimals, st.feed, st.maxStaleness, st.minPrice, st.maxPrice);
        }
    }

    /// @notice El Safe quita el rol a un guardián al instante (llave filtrada). Nombrar uno nuevo: Timelock.
    function revokeGuardian(address account) external onlyRole(SAFE_ROLE) {
        _revokeRole(GUARDIAN_ROLE, account);
    }

    // ═══════════════════════ Lecturas de precio ═══════════════════════

    function stableKey(address token) public pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    function feedConfig(bytes32 key) external view returns (FeedConfig memory) {
        return _feeds[key];
    }

    /// @notice Revierte si el sequencer de Arbitrum está caído, sin inicializar o en período de gracia.
    function checkSequencer() public view {
        // Solo se usan answer y startedAt (así lo indica la documentación de Chainlink para este feed).
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        // slither-disable-end unused-return
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0) revert SequencerNotInitialized();
        if (block.timestamp - startedAt <= gracePeriod) revert GracePeriodNotOver();
    }

    /// @notice Precio validado y normalizado a 18 decimales.
    function price(bytes32 key) public view returns (uint256) {
        FeedConfig memory c = _feeds[key];
        if (address(c.feed) == address(0)) revert FeedNotSet(key);

        (int256 answer, uint256 updatedAt) = _latest(c.feed, key);

        if (answer <= 0) revert InvalidPrice(key);
        if (updatedAt == 0 || updatedAt > block.timestamp) revert InvalidPrice(key);
        if (block.timestamp - updatedAt > c.maxStaleness) revert StalePrice(key);

        // answer > 0 verificado arriba: la conversión es segura
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 p = _normalize(uint256(answer), c.decimals);
        if (p < c.minPrice || p > c.maxPrice) revert PriceOutOfRange(key);
        return p;
    }

    /// @notice Cuántos BTC vale 1 WBTC (1e18 = paridad perfecta).
    function wrapperRatio() public view returns (uint256) {
        return price(WBTC_BTC);
    }

    /// @notice Precio en USD de 1 WBTC entero = BTC/USD × WBTC/BTC (nunca se supone 1:1).
    function wbtcUsd() public view returns (uint256) {
        return Math.mulDiv(price(BTC_USD), wrapperRatio(), WAD);
    }

    function ethUsd() public view returns (uint256) {
        return price(ETH_USD);
    }

    function stableUsd(address token) public view returns (uint256) {
        if (stableDecimals[token] == 0) revert StableNotSupported(token);
        return price(stableKey(token));
    }

    /// @notice Valor en USD (18 decimales) de una cantidad de WBTC y WETH.
    function basketValueUsd(uint256 btcAmount, uint256 ethAmount) public view returns (uint256) {
        return Math.mulDiv(btcAmount, wbtcUsd(), 10 ** BTC_DECIMALS)
            + Math.mulDiv(ethAmount, ethUsd(), 10 ** ETH_DECIMALS);
    }

    /// @notice Valor en USD (18 decimales) de una cantidad de stablecoin, a su precio real.
    function stableValueUsd(address token, uint256 amount) public view returns (uint256) {
        uint256 p = stableUsd(token);
        if (p < minStablePrice) revert StablePriceTooLow(token);
        return Math.mulDiv(amount, p, 10 ** stableDecimals[token]);
    }

    /// @notice Precio en USD de 1 token del índice (solo informativo, para la interfaz).
    function indexPriceUsd(uint256 unitBtc, uint256 unitEth) external view returns (uint256) {
        return basketValueUsd(unitBtc, unitEth);
    }

    /// @notice true si el wrapper está por debajo del umbral de alerta (para monitoreo e interfaz).
    function wrapperAlert() external view returns (bool) {
        return wrapperRatio() < wrapperAlertThreshold;
    }

    // ═══════════════════════ Controles para el Router ═══════════════════════

    /// @notice Valida una compra: `stableIn` (ya sin comisión) se convirtió en `btcOut` + `ethOut`.
    function checkBuy(address stable, uint256 stableIn, uint256 btcOut, uint256 ethOut) external view {
        checkSequencer();
        if (wrapperRatio() < wrapperBlockThreshold) revert WrapperDepegged();
        uint256 valueIn = stableValueUsd(stable, stableIn);
        uint256 valueOut = basketValueUsd(btcOut, ethOut);
        _checkMargin(valueIn, valueOut);
    }

    /// @notice Valida una venta: `btcIn` + `ethIn` se convirtieron en `stableOut` (antes de comisión).
    /// @dev Con el wrapper devaluado las ventas siguen permitidas: el usuario sale al precio real.
    function checkSell(address stable, uint256 btcIn, uint256 ethIn, uint256 stableOut) external view {
        checkSequencer();
        uint256 valueIn = basketValueUsd(btcIn, ethIn);
        uint256 valueOut = stableValueUsd(stable, stableOut);
        _checkMargin(valueIn, valueOut);
    }

    function _checkMargin(uint256 valueIn, uint256 valueOut) internal view {
        if (valueOut * BPS < valueIn * (BPS - marginBps)) revert ExecutionWorseThanOracle(valueIn, valueOut);
    }

    /// @dev Lee el feed; si la llamada falla, revierte con un error claro.
    function _latest(AggregatorV3Interface feed, bytes32 key)
        internal
        view
        returns (int256 answer, uint256 updatedAt)
    {
        // Solo se usan answer y updatedAt; roundId/answeredInRound están deprecados según Chainlink.
        // slither-disable-next-line unused-return
        try feed.latestRoundData() returns (uint80, int256 a, uint256, uint256 u, uint80) {
            return (a, u);
        } catch {
            revert FeedCallFailed(key);
        }
    }

    function _normalize(uint256 answer, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return answer;
        if (dec < 18) return answer * 10 ** (18 - dec);
        return answer / 10 ** (dec - 18);
    }

    // ═══════════════════ Configuración (administrador / Timelock) ═══════════════════

    /// @notice Configura un feed. Verifica que responda y lee sus decimales on-chain.
    function setFeed(
        bytes32 key,
        AggregatorV3Interface feed,
        uint32 maxStaleness,
        uint96 minPrice,
        uint96 maxPrice
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeed(key, feed, maxStaleness, minPrice, maxPrice);
    }

    function setStable(
        address token,
        uint8 tokenDecimals,
        AggregatorV3Interface feed,
        uint32 maxStaleness,
        uint96 minPrice,
        uint96 maxPrice
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setStable(token, tokenDecimals, feed, maxStaleness, minPrice, maxPrice);
    }

    // Se usa también desde el constructor (bucle de configuración inicial): avisos de bucle esperados.
    // forge-lint: disable-start(require-revert-in-loop)
    function _setStable(
        address token,
        uint8 tokenDecimals,
        AggregatorV3Interface feed,
        uint32 maxStaleness,
        uint96 minPrice,
        uint96 maxPrice
    ) internal {
        if (token == address(0)) revert ZeroAddress();
        if (tokenDecimals == 0) revert InvalidFeed();
        stableDecimals[token] = tokenDecimals;
        _setFeed(stableKey(token), feed, maxStaleness, minPrice, maxPrice);
        emit StableSet(token, tokenDecimals);
    }
    // forge-lint: disable-end(require-revert-in-loop)

    function setSequencerFeed(AggregatorV3Interface feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(feed) == address(0)) revert ZeroAddress();
        sequencerFeed = feed;
        emit SequencerFeedSet(address(feed));
    }

    // Se usa también desde el constructor (bucle de configuración inicial): avisos de bucle esperados.
    // forge-lint: disable-start(calls-loop, require-revert-in-loop)
    // slither-disable-start calls-loop
    function _setFeed(
        bytes32 key,
        AggregatorV3Interface feed,
        uint32 maxStaleness,
        uint96 minPrice,
        uint96 maxPrice
    ) internal {
        if (address(feed) == address(0)) revert ZeroAddress();
        if (maxStaleness == 0 || maxStaleness > MAX_STALENESS_CAP || minPrice >= maxPrice) {
            revert OutOfBounds();
        }
        uint8 dec = feed.decimals();
        if (dec == 0 || dec > 36) revert InvalidFeed();
        // El feed debe responder con un precio válido al configurarlo.
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return)
        (, int256 a,, uint256 u,) = feed.latestRoundData();
        // slither-disable-end unused-return
        if (a <= 0 || u == 0) revert InvalidFeed();
        _feeds[key] = FeedConfig(feed, maxStaleness, dec, minPrice, maxPrice);
        emit FeedSet(key, address(feed), maxStaleness, minPrice, maxPrice);
    }
    // slither-disable-end calls-loop
    // forge-lint: disable-end(calls-loop, require-revert-in-loop)

    // ═══════════════ Parámetros: endurecer (guardián) / relajar (Timelock) ═══════════════

    function tightenMargin(uint256 newBps) external onlyRole(GUARDIAN_ROLE) {
        if (newBps >= marginBps) revert NotTighter();
        uint256 old = marginBps;
        marginBps = newBps;
        emit ParamChanged("marginBps", old, newBps);
    }

    function relaxMargin(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps <= marginBps) revert NotLooser();
        if (newBps > MAX_MARGIN_BPS) revert OutOfBounds();
        uint256 old = marginBps;
        marginBps = newBps;
        emit ParamChanged("marginBps", old, newBps);
    }

    function tightenStaleness(bytes32 key, uint32 newMax) external onlyRole(GUARDIAN_ROLE) {
        FeedConfig storage c = _feeds[key];
        if (address(c.feed) == address(0)) revert FeedNotSet(key);
        if (newMax >= c.maxStaleness || newMax == 0) revert NotTighter();
        uint256 old = c.maxStaleness;
        c.maxStaleness = newMax;
        emit ParamChanged(key, old, newMax);
    }

    function relaxStaleness(bytes32 key, uint32 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FeedConfig storage c = _feeds[key];
        if (address(c.feed) == address(0)) revert FeedNotSet(key);
        if (newMax <= c.maxStaleness) revert NotLooser();
        if (newMax > MAX_STALENESS_CAP) revert OutOfBounds();
        uint256 old = c.maxStaleness;
        c.maxStaleness = newMax;
        emit ParamChanged(key, old, newMax);
    }

    function tightenGracePeriod(uint256 newGrace) external onlyRole(GUARDIAN_ROLE) {
        if (newGrace <= gracePeriod) revert NotTighter();
        if (newGrace > 1 days) revert OutOfBounds();
        uint256 old = gracePeriod;
        gracePeriod = newGrace;
        emit ParamChanged("gracePeriod", old, newGrace);
    }

    function relaxGracePeriod(uint256 newGrace) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGrace >= gracePeriod) revert NotLooser();
        if (newGrace < MIN_GRACE_PERIOD) revert OutOfBounds();
        uint256 old = gracePeriod;
        gracePeriod = newGrace;
        emit ParamChanged("gracePeriod", old, newGrace);
    }

    function tightenWrapperThreshold(uint256 newThreshold) external onlyRole(GUARDIAN_ROLE) {
        if (newThreshold <= wrapperBlockThreshold) revert NotTighter();
        if (newThreshold > WAD) revert OutOfBounds();
        uint256 old = wrapperBlockThreshold;
        wrapperBlockThreshold = newThreshold;
        emit ParamChanged("wrapperBlockThreshold", old, newThreshold);
    }

    function relaxWrapperThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold >= wrapperBlockThreshold) revert NotLooser();
        if (newThreshold < MIN_WRAPPER_THRESHOLD) revert OutOfBounds();
        uint256 old = wrapperBlockThreshold;
        wrapperBlockThreshold = newThreshold;
        emit ParamChanged("wrapperBlockThreshold", old, newThreshold);
    }

    function setWrapperAlertThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold < MIN_WRAPPER_THRESHOLD || newThreshold > WAD) revert OutOfBounds();
        uint256 old = wrapperAlertThreshold;
        wrapperAlertThreshold = newThreshold;
        emit ParamChanged("wrapperAlertThreshold", old, newThreshold);
    }

    function tightenMinStablePrice(uint256 newMin) external onlyRole(GUARDIAN_ROLE) {
        if (newMin <= minStablePrice) revert NotTighter();
        if (newMin > WAD) revert OutOfBounds();
        uint256 old = minStablePrice;
        minStablePrice = newMin;
        emit ParamChanged("minStablePrice", old, newMin);
    }

    function relaxMinStablePrice(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMin >= minStablePrice) revert NotLooser();
        if (newMin < MIN_STABLE_PRICE_FLOOR) revert OutOfBounds();
        uint256 old = minStablePrice;
        minStablePrice = newMin;
        emit ParamChanged("minStablePrice", old, newMin);
    }
}
