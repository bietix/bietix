// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title OracleGuard — red de seguridad de precios para el Router de BIETIX
/// @author Bietix
/// @notice Lee Chainlink (BTC/USD, ETH/USD, WBTC/BTC, stablecoins y Sequencer Uptime de Arbitrum) y
///         revierte si algún dato es inválido o si un swap rindió peor que el oráculo más allá del margen.
/// @dev El núcleo (BietixVault) NO usa este contrato. Si falla, solo se detiene el Router y la salida
///      In-Kind sigue abierta. Ver Especificaciones Técnicas, sección 4.
///      Regla de permisos: endurecer = guardián (inmediato); relajar = administrador/Timelock (con espera).
contract OracleGuard is AccessControlDefaultAdminRules {
    /// @notice Respuesta rápida: solo puede endurecer parámetros.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Safe multisig: puede revocar guardianes al instante.
    bytes32 public constant SAFE_ROLE = keccak256("SAFE_ROLE");

    /// @notice Clave del feed BTC/USD.
    bytes32 public constant BTC_USD = keccak256("BTC_USD");
    /// @notice Clave del feed ETH/USD.
    bytes32 public constant ETH_USD = keccak256("ETH_USD");
    /// @notice Clave del feed WBTC/BTC (paridad del wrapper).
    bytes32 public constant WBTC_BTC = keccak256("WBTC_BTC");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    // ─────────────── Techos y pisos fijos en código (sección 4.9) ───────────────
    /// @notice Margen máximo contra oráculo (3%).
    uint256 public constant MAX_MARGIN_BPS = 300;
    /// @notice Antigüedad máxima configurable de un feed.
    uint256 public constant MAX_STALENESS_CAP = 26 hours;
    /// @notice Período de gracia mínimo tras volver el sequencer.
    uint256 public constant MIN_GRACE_PERIOD = 30 minutes;
    /// @notice Piso del umbral de bloqueo/alerta del wrapper (0,95 BTC por WBTC).
    uint256 public constant MIN_WRAPPER_THRESHOLD = 0.95e18;
    /// @notice Piso del precio mínimo aceptado para una stablecoin (0,95 USD).
    uint256 public constant MIN_STABLE_PRICE_FLOOR = 0.95e18;

    // ───────────── Valores iniciales (después se ajustan dentro de los topes) ─────────────
    /// @notice Período de gracia inicial del sequencer.
    uint256 public constant DEFAULT_GRACE_PERIOD = 1 hours;
    /// @notice Margen inicial contra oráculo (1%).
    uint256 public constant DEFAULT_MARGIN_BPS = 100;
    /// @notice Umbral inicial de bloqueo de compras por paridad de WBTC.
    uint256 public constant DEFAULT_WRAPPER_BLOCK = 0.98e18;
    /// @notice Umbral inicial de alerta por paridad de WBTC.
    uint256 public constant DEFAULT_WRAPPER_ALERT = 0.99e18;
    /// @notice Precio mínimo inicial aceptado para una stablecoin.
    uint256 public constant DEFAULT_MIN_STABLE_PRICE = 0.98e18;

    /// @notice Feed a configurar en el despliegue.
    /// @param key clave del feed (BTC_USD, ETH_USD o WBTC_BTC)
    /// @param feed agregador de Chainlink
    /// @param maxStaleness antigüedad máxima en segundos
    /// @param minPrice precio mínimo aceptado (18 decimales)
    /// @param maxPrice precio máximo aceptado (18 decimales)
    struct FeedInit {
        bytes32 key;
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint96 minPrice;
        uint96 maxPrice;
    }

    /// @notice Stablecoin a configurar en el despliegue.
    /// @param token dirección de la stablecoin
    /// @param decimals decimales del token (se verifican on-chain)
    /// @param feed agregador de Chainlink del token en USD
    /// @param maxStaleness antigüedad máxima en segundos
    /// @param minPrice precio mínimo aceptado (18 decimales)
    /// @param maxPrice precio máximo aceptado (18 decimales)
    struct StableInit {
        address token;
        uint8 decimals;
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint96 minPrice;
        uint96 maxPrice;
    }

    /// @notice Configuración guardada de cada feed.
    /// @param feed agregador de Chainlink
    /// @param maxStaleness antigüedad máxima en segundos
    /// @param decimals decimales del feed (leídos on-chain)
    /// @param minPrice rango de cordura, normalizado a 18 decimales
    /// @param maxPrice rango de cordura, normalizado a 18 decimales
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxStaleness; // segundos
        uint8 decimals; // decimales del feed
        uint96 minPrice; // rango de cordura, normalizado a 18 decimales
        uint96 maxPrice;
    }

    /// @notice Decimales del activo BTC (WBTC = 8).
    uint8 public immutable BTC_DECIMALS;
    /// @notice Decimales del activo ETH (WETH = 18).
    uint8 public immutable ETH_DECIMALS;

    /// @notice Feed Sequencer Uptime de Arbitrum.
    AggregatorV3Interface public sequencerFeed;
    /// @notice Segundos que se espera después de que el sequencer vuelve antes de aceptar precios.
    uint256 public gracePeriod;
    /// @notice Diferencia máxima tolerada entre la ejecución y el oráculo, en bps.
    uint256 public marginBps;
    /// @notice Por debajo de esta paridad WBTC/BTC se bloquean las compras (18 decimales).
    uint256 public wrapperBlockThreshold;
    /// @notice Por debajo de esta paridad se activa la alerta (solo informativo, 18 decimales).
    uint256 public wrapperAlertThreshold;
    /// @notice Precio mínimo en USD para aceptar una stablecoin (18 decimales).
    uint256 public minStablePrice;

    /// @notice clave → configuración del feed. Para stablecoins la clave es stableKey(token).
    mapping(bytes32 => FeedConfig) internal _feeds;
    /// @notice decimales de cada stablecoin configurada (0 = no configurada).
    mapping(address => uint8) public stableDecimals;

    /// @notice Se configuró un feed.
    /// @param key clave del feed
    /// @param feed agregador
    /// @param maxStaleness antigüedad máxima en segundos
    /// @param minPrice precio mínimo aceptado
    /// @param maxPrice precio máximo aceptado
    event FeedSet(bytes32 indexed key, address feed, uint32 maxStaleness, uint96 minPrice, uint96 maxPrice);
    /// @notice Se configuró una stablecoin.
    /// @param token stablecoin
    /// @param decimals decimales verificados
    event StableSet(address indexed token, uint8 decimals);
    /// @notice Cambió el feed del sequencer.
    /// @param feed feed nuevo
    event SequencerFeedSet(address indexed feed);
    /// @notice Cambió un parámetro (margen, gracia, umbrales o la antigüedad de un feed).
    /// @param param nombre del parámetro, o clave del feed para la antigüedad
    /// @param oldValue valor anterior
    /// @param newValue valor nuevo
    event ParamChanged(bytes32 indexed param, uint256 oldValue, uint256 newValue);

    /// @notice Se pasó la dirección cero.
    error ZeroAddress();
    /// @notice No hay feed configurado para la clave.
    /// @param key clave pedida
    error FeedNotSet(bytes32 key);
    /// @notice La llamada al feed revirtió.
    /// @param key clave del feed
    error FeedCallFailed(bytes32 key);
    /// @notice Precio en cero o negativo, o fecha inválida.
    /// @param key clave del feed
    error InvalidPrice(bytes32 key);
    /// @notice El precio es más viejo que `maxStaleness`.
    /// @param key clave del feed
    error StalePrice(bytes32 key);
    /// @notice El precio está fuera del rango de cordura.
    /// @param key clave del feed
    error PriceOutOfRange(bytes32 key);
    /// @notice El sequencer de Arbitrum está caído.
    error SequencerDown();
    /// @notice El feed del sequencer todavía no tiene datos.
    error SequencerNotInitialized();
    /// @notice El sequencer volvió hace menos que `gracePeriod`.
    error GracePeriodNotOver();
    /// @notice La stablecoin no está configurada.
    /// @param token stablecoin pedida
    error StableNotSupported(address token);
    /// @notice La stablecoin cotiza por debajo de `minStablePrice`.
    /// @param token stablecoin
    error StablePriceTooLow(address token);
    /// @notice WBTC cotiza por debajo de `wrapperBlockThreshold`.
    error WrapperDepegged();
    /// @notice La operación rindió peor que el oráculo menos el margen.
    /// @param valueIn valor de lo entregado (USD, 18 decimales)
    /// @param valueOut valor de lo recibido (USD, 18 decimales)
    error ExecutionWorseThanOracle(uint256 valueIn, uint256 valueOut);
    /// @notice El guardián intentó un cambio que no endurece el parámetro.
    error NotTighter();
    /// @notice El administrador intentó relajar con un valor que no relaja.
    error NotLooser();
    /// @notice Valor fuera de los topes fijos en código.
    error OutOfBounds();
    /// @notice Feed o configuración inválidos (decimales, respuesta inicial).
    error InvalidFeed();
    /// @notice Los decimales declarados no coinciden con los del token.
    /// @param token stablecoin
    error DecimalsMismatch(address token);

    /// @notice Despliega el oráculo con todos sus feeds configurados.
    /// @param admin administrador (Timelock)
    /// @param adminTransferDelay espera para transferir el rol de administrador
    /// @param safe Safe multisig (SAFE_ROLE y GUARDIAN_ROLE)
    /// @param guardian billetera de respuesta rápida
    /// @param btcDecimals decimales de WBTC
    /// @param ethDecimals decimales de WETH
    /// @param sequencerFeed_ feed Sequencer Uptime
    /// @param initFeeds feeds BTC/USD, ETH/USD y WBTC/BTC
    /// @param initStables stablecoins aceptadas
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

        gracePeriod = DEFAULT_GRACE_PERIOD;
        marginBps = DEFAULT_MARGIN_BPS;
        wrapperBlockThreshold = DEFAULT_WRAPPER_BLOCK;
        wrapperAlertThreshold = DEFAULT_WRAPPER_ALERT;
        minStablePrice = DEFAULT_MIN_STABLE_PRICE;

        _grantRole(SAFE_ROLE, safe);
        _grantRole(GUARDIAN_ROLE, safe);
        _grantRole(GUARDIAN_ROLE, guardian);

        // Configuración inicial en el mismo despliegue: así quien despliega nunca necesita permisos.
        for (uint256 i; i < initFeeds.length; ++i) {
            FeedInit memory f = initFeeds[i];
            _setFeed(f.key, f.feed, f.maxStaleness, f.minPrice, f.maxPrice);
        }
        for (uint256 i; i < initStables.length; ++i) {
            StableInit memory st = initStables[i];
            _setStable(st.token, st.decimals, st.feed, st.maxStaleness, st.minPrice, st.maxPrice);
        }
    }

    /// @notice El Safe quita el rol a un guardián al instante (llave filtrada). Nombrar uno nuevo: Timelock.
    /// @param account guardián a quitar
    function revokeGuardian(address account) external onlyRole(SAFE_ROLE) {
        _revokeRole(GUARDIAN_ROLE, account);
    }

    // ═══════════════════════ Lecturas de precio ═══════════════════════

    /// @notice Clave interna del feed de una stablecoin.
    /// @param token stablecoin
    /// @return clave derivada de la dirección
    function stableKey(address token) public pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    /// @notice Configuración de un feed.
    /// @param key clave del feed
    /// @return configuración guardada (feed en cero si no existe)
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
    /// @dev Revierte si el feed no existe, falla, da un valor inválido, viejo o fuera de rango.
    /// @param key clave del feed
    /// @return precio con 18 decimales
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
    /// @return paridad con 18 decimales
    function wrapperRatio() public view returns (uint256) {
        return price(WBTC_BTC);
    }

    /// @notice Precio en USD de 1 WBTC entero = BTC/USD × WBTC/BTC (nunca se supone 1:1).
    /// @return precio con 18 decimales
    function wbtcUsd() public view returns (uint256) {
        return Math.mulDiv(price(BTC_USD), wrapperRatio(), WAD);
    }

    /// @notice Precio en USD de 1 ETH.
    /// @return precio con 18 decimales
    function ethUsd() public view returns (uint256) {
        return price(ETH_USD);
    }

    /// @notice Precio en USD de una stablecoin configurada.
    /// @param token stablecoin
    /// @return precio con 18 decimales
    function stableUsd(address token) public view returns (uint256) {
        if (stableDecimals[token] == 0) revert StableNotSupported(token);
        return price(stableKey(token));
    }

    /// @notice Valor en USD (18 decimales) de una cantidad de WBTC y WETH.
    /// @param btcAmount unidades mínimas de WBTC
    /// @param ethAmount unidades mínimas de WETH
    /// @return valor en USD
    function basketValueUsd(uint256 btcAmount, uint256 ethAmount) public view returns (uint256) {
        return Math.mulDiv(btcAmount, wbtcUsd(), 10 ** BTC_DECIMALS)
            + Math.mulDiv(ethAmount, ethUsd(), 10 ** ETH_DECIMALS);
    }

    /// @notice Valor en USD (18 decimales) de una cantidad de stablecoin, a su precio real.
    /// @dev Revierte si la stablecoin cotiza por debajo de `minStablePrice`.
    /// @param token stablecoin
    /// @param amount unidades mínimas
    /// @return valor en USD
    function stableValueUsd(address token, uint256 amount) public view returns (uint256) {
        uint256 p = stableUsd(token);
        if (p < minStablePrice) revert StablePriceTooLow(token);
        return Math.mulDiv(amount, p, 10 ** stableDecimals[token]);
    }

    /// @notice Precio en USD de 1 token del índice (solo informativo, para la interfaz).
    /// @param unitBtc UNIT_BTC del vault
    /// @param unitEth UNIT_ETH del vault
    /// @return precio con 18 decimales
    function indexPriceUsd(uint256 unitBtc, uint256 unitEth) external view returns (uint256) {
        return basketValueUsd(unitBtc, unitEth);
    }

    /// @notice true si el wrapper está por debajo del umbral de alerta (para monitoreo e interfaz).
    /// @return si hay alerta
    function wrapperAlert() external view returns (bool) {
        return wrapperRatio() < wrapperAlertThreshold;
    }

    // ═══════════════════════ Controles para el Router ═══════════════════════

    /// @notice Valida una compra: `stableIn` (ya sin comisión) se convirtió en `btcOut` + `ethOut`.
    /// @dev Revierte con el sequencer caído, el wrapper devaluado, la stable fuera de rango o mala ejecución.
    /// @param stable stablecoin usada
    /// @param stableIn monto de stable que se cambió
    /// @param btcOut WBTC recibido
    /// @param ethOut WETH recibido
    function checkBuy(address stable, uint256 stableIn, uint256 btcOut, uint256 ethOut) external view {
        checkSequencer();
        if (wrapperRatio() < wrapperBlockThreshold) revert WrapperDepegged();
        uint256 valueIn = stableValueUsd(stable, stableIn);
        uint256 valueOut = basketValueUsd(btcOut, ethOut);
        _checkMargin(valueIn, valueOut);
    }

    /// @notice Valida una venta: `btcIn` + `ethIn` se convirtieron en `stableOut` (antes de comisión).
    /// @dev Con el wrapper devaluado las ventas siguen permitidas: el usuario sale al precio real.
    /// @param stable stablecoin recibida
    /// @param btcIn WBTC vendido
    /// @param ethIn WETH vendido
    /// @param stableOut stable recibida antes de la comisión
    function checkSell(address stable, uint256 btcIn, uint256 ethIn, uint256 stableOut) external view {
        checkSequencer();
        uint256 valueIn = basketValueUsd(btcIn, ethIn);
        uint256 valueOut = stableValueUsd(stable, stableOut);
        _checkMargin(valueIn, valueOut);
    }

    /// @dev Revierte si lo recibido vale menos que lo entregado menos `marginBps`.
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

    /// @dev Lleva un precio de `dec` decimales a 18.
    function _normalize(uint256 answer, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return answer;
        if (dec < 18) return answer * 10 ** (18 - dec);
        return answer / 10 ** (dec - 18);
    }

    // ═══════════════════ Configuración (administrador / Timelock) ═══════════════════

    /// @notice Configura un feed. Verifica que responda y lee sus decimales on-chain.
    /// @param key clave del feed
    /// @param feed agregador de Chainlink
    /// @param maxStaleness antigüedad máxima (hasta MAX_STALENESS_CAP)
    /// @param minPrice precio mínimo aceptado (18 decimales)
    /// @param maxPrice precio máximo aceptado (18 decimales)
    function setFeed(
        bytes32 key,
        AggregatorV3Interface feed,
        uint32 maxStaleness,
        uint96 minPrice,
        uint96 maxPrice
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeed(key, feed, maxStaleness, minPrice, maxPrice);
    }

    /// @notice Agrega o reconfigura una stablecoin y su feed.
    /// @param token stablecoin
    /// @param tokenDecimals decimales del token (se verifican on-chain)
    /// @param feed agregador del token en USD
    /// @param maxStaleness antigüedad máxima (hasta MAX_STALENESS_CAP)
    /// @param minPrice precio mínimo aceptado (18 decimales)
    /// @param maxPrice precio máximo aceptado (18 decimales)
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
    // forge-lint: disable-start(require-revert-in-loop, calls-loop)
    // slither-disable-start calls-loop

    /// @dev Configura una stable: verifica sus decimales contra el token y configura su feed.
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
        // Los decimales se confirman contra el propio token: un error de tipeo valuaría mal cada compra.
        // Llamada de bajo nivel para que una dirección sin código revierta con un error claro.
        // solhint-disable avoid-low-level-calls
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        // solhint-enable avoid-low-level-calls
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != tokenDecimals) {
            revert DecimalsMismatch(token);
        }
        stableDecimals[token] = tokenDecimals;
        _setFeed(stableKey(token), feed, maxStaleness, minPrice, maxPrice);
        emit StableSet(token, tokenDecimals);
    }

    // slither-disable-end calls-loop
    // forge-lint: disable-end(require-revert-in-loop, calls-loop)

    /// @notice Cambia el feed del sequencer.
    /// @param feed feed nuevo
    function setSequencerFeed(AggregatorV3Interface feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(feed) == address(0)) revert ZeroAddress();
        sequencerFeed = feed;
        emit SequencerFeedSet(address(feed));
    }

    // Se usa también desde el constructor (bucle de configuración inicial): avisos de bucle esperados.
    // forge-lint: disable-start(calls-loop, require-revert-in-loop)
    // slither-disable-start calls-loop

    /// @dev Configura un feed: valida los topes, lee sus decimales y exige que responda con un precio válido.
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

    /// @notice Baja el margen tolerado (guardián, inmediato).
    /// @param newBps margen nuevo, menor al actual
    function tightenMargin(uint256 newBps) external onlyRole(GUARDIAN_ROLE) {
        if (newBps >= marginBps) revert NotTighter();
        uint256 old = marginBps;
        marginBps = newBps;
        emit ParamChanged("marginBps", old, newBps);
    }

    /// @notice Sube el margen tolerado (Timelock, hasta MAX_MARGIN_BPS).
    /// @param newBps margen nuevo, mayor al actual
    function relaxMargin(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps <= marginBps) revert NotLooser();
        if (newBps > MAX_MARGIN_BPS) revert OutOfBounds();
        uint256 old = marginBps;
        marginBps = newBps;
        emit ParamChanged("marginBps", old, newBps);
    }

    /// @notice Exige precios más recientes en un feed (guardián, inmediato).
    /// @param key clave del feed
    /// @param newMax antigüedad máxima nueva, menor a la actual
    function tightenStaleness(bytes32 key, uint32 newMax) external onlyRole(GUARDIAN_ROLE) {
        FeedConfig storage c = _feeds[key];
        if (address(c.feed) == address(0)) revert FeedNotSet(key);
        if (newMax >= c.maxStaleness || newMax == 0) revert NotTighter();
        uint256 old = c.maxStaleness;
        c.maxStaleness = newMax;
        emit ParamChanged(key, old, newMax);
    }

    /// @notice Acepta precios más viejos en un feed (Timelock, hasta MAX_STALENESS_CAP).
    /// @param key clave del feed
    /// @param newMax antigüedad máxima nueva, mayor a la actual
    function relaxStaleness(bytes32 key, uint32 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FeedConfig storage c = _feeds[key];
        if (address(c.feed) == address(0)) revert FeedNotSet(key);
        if (newMax <= c.maxStaleness) revert NotLooser();
        if (newMax > MAX_STALENESS_CAP) revert OutOfBounds();
        uint256 old = c.maxStaleness;
        c.maxStaleness = newMax;
        emit ParamChanged(key, old, newMax);
    }

    /// @notice Alarga el período de gracia del sequencer (guardián, hasta 1 día).
    /// @param newGrace período nuevo, mayor al actual
    function tightenGracePeriod(uint256 newGrace) external onlyRole(GUARDIAN_ROLE) {
        if (newGrace <= gracePeriod) revert NotTighter();
        if (newGrace > 1 days) revert OutOfBounds();
        uint256 old = gracePeriod;
        gracePeriod = newGrace;
        emit ParamChanged("gracePeriod", old, newGrace);
    }

    /// @notice Acorta el período de gracia (Timelock, desde MIN_GRACE_PERIOD).
    /// @param newGrace período nuevo, menor al actual
    function relaxGracePeriod(uint256 newGrace) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGrace >= gracePeriod) revert NotLooser();
        if (newGrace < MIN_GRACE_PERIOD) revert OutOfBounds();
        uint256 old = gracePeriod;
        gracePeriod = newGrace;
        emit ParamChanged("gracePeriod", old, newGrace);
    }

    /// @notice Sube el umbral de bloqueo de WBTC (guardián, hasta 1,0).
    /// @param newThreshold umbral nuevo, mayor al actual
    function tightenWrapperThreshold(uint256 newThreshold) external onlyRole(GUARDIAN_ROLE) {
        if (newThreshold <= wrapperBlockThreshold) revert NotTighter();
        if (newThreshold > WAD) revert OutOfBounds();
        uint256 old = wrapperBlockThreshold;
        wrapperBlockThreshold = newThreshold;
        emit ParamChanged("wrapperBlockThreshold", old, newThreshold);
    }

    /// @notice Baja el umbral de bloqueo de WBTC (Timelock, desde MIN_WRAPPER_THRESHOLD).
    /// @param newThreshold umbral nuevo, menor al actual
    function relaxWrapperThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold >= wrapperBlockThreshold) revert NotLooser();
        if (newThreshold < MIN_WRAPPER_THRESHOLD) revert OutOfBounds();
        uint256 old = wrapperBlockThreshold;
        wrapperBlockThreshold = newThreshold;
        emit ParamChanged("wrapperBlockThreshold", old, newThreshold);
    }

    /// @notice Cambia el umbral de alerta de WBTC (Timelock; solo informativo).
    /// @param newThreshold umbral nuevo, entre MIN_WRAPPER_THRESHOLD y 1,0
    function setWrapperAlertThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold < MIN_WRAPPER_THRESHOLD || newThreshold > WAD) revert OutOfBounds();
        uint256 old = wrapperAlertThreshold;
        wrapperAlertThreshold = newThreshold;
        emit ParamChanged("wrapperAlertThreshold", old, newThreshold);
    }

    /// @notice Sube el precio mínimo aceptado de las stablecoins (guardián, hasta 1,0).
    /// @param newMin mínimo nuevo, mayor al actual
    function tightenMinStablePrice(uint256 newMin) external onlyRole(GUARDIAN_ROLE) {
        if (newMin <= minStablePrice) revert NotTighter();
        if (newMin > WAD) revert OutOfBounds();
        uint256 old = minStablePrice;
        minStablePrice = newMin;
        emit ParamChanged("minStablePrice", old, newMin);
    }

    /// @notice Baja el precio mínimo aceptado (Timelock, desde MIN_STABLE_PRICE_FLOOR).
    /// @param newMin mínimo nuevo, menor al actual
    function relaxMinStablePrice(uint256 newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMin >= minStablePrice) revert NotLooser();
        if (newMin < MIN_STABLE_PRICE_FLOOR) revert OutOfBounds();
        uint256 old = minStablePrice;
        minStablePrice = newMin;
        emit ParamChanged("minStablePrice", old, newMin);
    }
}
