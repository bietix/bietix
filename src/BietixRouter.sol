// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BietixVault} from "./BietixVault.sol";
import {OracleGuard} from "./OracleGuard.sol";

/// @title BietixRouter — compra y venta de BIETIX con stablecoins
/// @author Bietix
/// @notice Convierte USDC/USDT ↔ WBTC/WETH mediante agregadores en lista blanca y llama al vault como
///         cualquier usuario. No retiene fondos entre transacciones y es reemplazable sin migrar nada.
/// @dev Ver Especificaciones Técnicas, secciones 1.4 y 3. Comisión total de compra = comisión del Router
///      + comisión In-Kind del vault (el Router paga la del vault como cualquier usuario).
contract BietixRouter is AccessControlDefaultAdminRules, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Respuesta rápida: pausar, bajar límites y quitar stables o agregadores.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Safe multisig: despausar, revocar guardianes y rescatar tokens.
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @notice Tope fijo de las comisiones de compra y de venta del Router (1%).
    uint256 public constant MAX_FEE_BPS = 100;
    /// @notice Duración de la ventana móvil del cupo de ventas.
    uint256 public constant SELL_WINDOW = 1 days;

    /// @notice Autorización EIP-2612 firmada por el usuario (ver `buyWithPermit`).
    /// @param value monto autorizado (debe cubrir `amountIn`)
    /// @param deadline fecha límite de la firma
    /// @param v componente v de la firma
    /// @param r componente r de la firma
    /// @param s componente s de la firma
    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Un paso de swap: el Router aprueba `amountIn` de `tokenIn` a `target` y lo llama con `data`.
    /// @dev `target` debe estar en lista blanca y ser también quien toma los fondos (router del agregador).
    /// @param target contrato del agregador
    /// @param tokenIn token que entrega el Router
    /// @param amountIn monto exacto que se aprueba y entrega
    /// @param data datos de la llamada, armados por la API del agregador
    struct SwapStep {
        address target;
        address tokenIn;
        uint256 amountIn;
        bytes data;
    }

    /// @notice Vault del índice (inmutable).
    BietixVault public immutable VAULT;
    /// @notice WBTC, leído del vault.
    IERC20 public immutable ASSET_BTC;
    /// @notice WETH, leído del vault.
    IERC20 public immutable ASSET_ETH;

    /// @notice Oráculo usado para validar cada operación.
    OracleGuard public oracle;
    /// @notice Dirección que recibe las comisiones del Router.
    address public treasury;
    /// @notice Comisión de compra en bps, sobre el monto de stable entregado.
    uint256 public buyFeeBps;
    /// @notice Comisión de venta en bps, sobre la stable obtenida.
    uint256 public sellFeeBps;

    /// @notice Pausa total: compra y venta.
    bool public paused;
    /// @notice Pausa solo de compras.
    bool public buyPaused;
    /// @notice Pausa solo de ventas.
    bool public sellPaused;

    /// @notice Máximo por operación, en USD con 18 decimales.
    uint256 public maxTradeUsd;
    /// @notice Máximo de ventas a stablecoins por ventana móvil de 24 h, en USD con 18 decimales.
    uint256 public sellLimitUsd;
    /// @notice Ventas acumuladas (USD 1e18) al momento `sellUpdatedAt`. Se "descarga" linealmente:
    ///         el cupo completo se recupera en 24 h. Así no se puede vender 2 veces el límite en el cambio de ventana.
    uint256 public sellUsedUsd;
    /// @notice Momento de la última actualización de `sellUsedUsd`.
    uint256 public sellUpdatedAt;

    /// @notice Stablecoins aceptadas.
    mapping(address => bool) public isStable;
    /// @notice Agregadores permitidos.
    mapping(address => bool) public isSwapTarget;

    /// @notice Compra completada.
    /// @param user quien pagó
    /// @param receiver quien recibió los BIETIX
    /// @param stable stablecoin usada
    /// @param amountIn monto entregado (comisión incluida)
    /// @param fee comisión del Router
    /// @param shares BIETIX recibidos
    event Bought(
        address indexed user,
        address indexed receiver,
        address indexed stable,
        uint256 amountIn,
        uint256 fee,
        uint256 shares
    );
    /// @notice Venta completada.
    /// @param user quien vendió
    /// @param receiver quien recibió la stable
    /// @param stable stablecoin recibida
    /// @param shares BIETIX vendidos
    /// @param amountOut stable neta entregada
    /// @param fee comisión del Router
    event Sold(
        address indexed user,
        address indexed receiver,
        address indexed stable,
        uint256 shares,
        uint256 amountOut,
        uint256 fee
    );
    /// @notice Cambió una pausa.
    /// @param which "all", "buy" o "sell"
    /// @param value true = pausado
    event PauseChanged(bytes32 indexed which, bool value);
    /// @notice Se agregó o quitó una stablecoin.
    /// @param token stablecoin
    /// @param allowed true = aceptada
    event StableChanged(address indexed token, bool allowed);
    /// @notice Se agregó o quitó un agregador.
    /// @param target agregador
    /// @param allowed true = permitido
    event SwapTargetChanged(address indexed target, bool allowed);
    /// @notice Cambió un parámetro numérico (comisiones o límites).
    /// @param param nombre del parámetro
    /// @param oldValue valor anterior
    /// @param newValue valor nuevo
    event ParamChanged(bytes32 indexed param, uint256 oldValue, uint256 newValue);
    /// @notice Cambió el oráculo.
    /// @param oldOracle oráculo anterior
    /// @param newOracle oráculo nuevo
    event OracleChanged(address indexed oldOracle, address indexed newOracle);
    /// @notice Cambió la tesorería.
    /// @param oldTreasury tesorería anterior
    /// @param newTreasury tesorería nueva
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    /// @notice Se rescataron tokens enviados por error.
    /// @param token token rescatado
    /// @param amount cantidad
    /// @param to destino (tesorería)
    event Swept(address indexed token, uint256 amount, address indexed to);

    /// @notice Se pasó la dirección cero.
    error ZeroAddress();
    /// @notice Monto en cero.
    error ZeroAmount();
    /// @notice La operación está pausada.
    error IsPaused();
    /// @notice La stablecoin no está en la lista blanca (o no puede estarlo).
    /// @param token stablecoin
    error StableNotAllowed(address token);
    /// @notice El agregador no está en la lista blanca (o no puede estarlo).
    /// @param target agregador
    error TargetNotAllowed(address target);
    /// @notice Los pasos de swap no son válidos (token o monto no permitido, o ningún swap en la venta).
    error InvalidStep();
    /// @notice Pasó la fecha límite.
    error Expired();
    /// @notice La operación supera `maxTradeUsd`.
    /// @param valueUsd valor de la operación
    /// @param maxUsd máximo permitido
    error TradeTooLarge(uint256 valueUsd, uint256 maxUsd);
    /// @notice La venta superaría el cupo de 24 h.
    /// @param soldUsd ventas acumuladas con esta incluida
    /// @param limitUsd cupo
    error SellLimitExceeded(uint256 soldUsd, uint256 limitUsd);
    /// @notice Se recibiría menos que el mínimo pedido por el usuario.
    /// @param got lo que se recibiría
    /// @param min mínimo pedido
    error InsufficientOutput(uint256 got, uint256 min);
    /// @notice La llamada al agregador revirtió.
    /// @param target agregador
    error SwapFailed(address target);
    /// @notice La comisión supera MAX_FEE_BPS.
    error FeeTooHigh();
    /// @notice El valor nuevo no es menor al actual.
    error NotLower();
    /// @notice El valor nuevo no es mayor al actual.
    error NotHigher();
    /// @notice Un saldo no coincide con lo esperado (token con comisión o retención en el Router).
    /// @param token token afectado
    error BalanceMismatch(address token);

    /// @notice Configuración de despliegue.
    /// @param vault vault del índice
    /// @param oracle oráculo
    /// @param admin administrador (Timelock)
    /// @param adminTransferDelay espera para transferir el rol de administrador
    /// @param safe Safe multisig (UNPAUSER y GUARDIAN)
    /// @param guardian billetera de respuesta rápida
    /// @param treasury tesorería
    /// @param buyFeeBps comisión de compra
    /// @param sellFeeBps comisión de venta
    /// @param maxTradeUsd máximo por operación (USD, 18 decimales)
    /// @param sellLimitUsd cupo de ventas de 24 h (USD, 18 decimales)
    /// @param stables stablecoins habilitadas desde el despliegue
    /// @param swapTargets agregadores habilitados desde el despliegue
    struct Config {
        BietixVault vault;
        OracleGuard oracle;
        address admin; // Timelock
        uint48 adminTransferDelay;
        address safe;
        address guardian;
        address treasury;
        uint256 buyFeeBps;
        uint256 sellFeeBps;
        uint256 maxTradeUsd;
        uint256 sellLimitUsd;
        address[] stables; // stablecoins habilitadas desde el despliegue
        address[] swapTargets; // agregadores habilitados desde el despliegue
    }

    /// @notice Despliega el Router con toda su configuración inicial.
    /// @param c configuración (ver `Config`)
    constructor(Config memory c) AccessControlDefaultAdminRules(c.adminTransferDelay, c.admin) {
        if (
            address(c.vault) == address(0) || address(c.oracle) == address(0) || c.safe == address(0)
                || c.guardian == address(0) || c.treasury == address(0)
        ) revert ZeroAddress();
        if (c.buyFeeBps > MAX_FEE_BPS || c.sellFeeBps > MAX_FEE_BPS) revert FeeTooHigh();

        VAULT = c.vault;
        // Lectura del vault durante el despliegue: el Router todavía no tiene código, así que no hay reentrada posible.
        // aderyn-ignore-next-line(reentrancy-state-change)
        ASSET_BTC = c.vault.ASSET_BTC();
        // aderyn-ignore-next-line(reentrancy-state-change)
        ASSET_ETH = c.vault.ASSET_ETH();
        oracle = c.oracle;
        treasury = c.treasury;
        buyFeeBps = c.buyFeeBps;
        sellFeeBps = c.sellFeeBps;
        maxTradeUsd = c.maxTradeUsd;
        sellLimitUsd = c.sellLimitUsd;
        sellUpdatedAt = block.timestamp;

        _grantRole(UNPAUSER_ROLE, c.safe);
        _grantRole(GUARDIAN_ROLE, c.safe);
        _grantRole(GUARDIAN_ROLE, c.guardian);

        // Configuración inicial en el mismo despliegue: así quien despliega nunca necesita permisos.
        for (uint256 i; i < c.stables.length; ++i) {
            _addStable(c.stables[i]);
        }
        for (uint256 i; i < c.swapTargets.length; ++i) {
            _addSwapTarget(c.swapTargets[i]);
        }
    }

    // ═══════════════════════════════ Compra ═══════════════════════════════

    /// @notice Compra BIETIX con una stablecoin.
    /// @param stable stablecoin en lista blanca (USDC, USDT)
    /// @param amountIn monto total que entrega el usuario (comisión incluida)
    /// @param minShares mínimo de BIETIX que acepta recibir (protección contra slippage)
    /// @param steps swaps stable → WBTC y stable → WETH, armados fuera de la cadena con la API del agregador
    /// @param deadline fecha límite de la transacción
    /// @param receiver quién recibe los BIETIX
    /// @return shares BIETIX recibidos
    function buy(
        address stable,
        uint256 amountIn,
        uint256 minShares,
        SwapStep[] calldata steps,
        uint256 deadline,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        shares = _buy(stable, amountIn, minShares, steps, deadline, receiver);
    }

    /// @notice Igual que `buy`, pero con la autorización firmada (EIP-2612) en la misma transacción: el usuario
    ///         firma una sola vez. Solo para stablecoins que implementan `permit` (USDC; USDT no).
    /// @dev Si la firma ya se usó (alguien la copió del mempool y llamó a `permit` antes), `permit` revierte;
    ///      se ignora ese error y se sigue, porque la autorización ya quedó hecha. Si no hay autorización,
    ///      `safeTransferFrom` revierte igual. La firma solo puede autorizar a este Router.
    /// @param stable stablecoin con `permit` en lista blanca (USDC)
    /// @param amountIn monto total que entrega el usuario (comisión incluida)
    /// @param minShares mínimo de BIETIX que acepta recibir
    /// @param steps swaps stable → WBTC y stable → WETH
    /// @param deadline fecha límite de la transacción
    /// @param receiver quién recibe los BIETIX
    /// @param permit_ autorización firmada por `msg.sender` a favor de este Router
    /// @return shares BIETIX recibidos
    function buyWithPermit(
        address stable,
        uint256 amountIn,
        uint256 minShares,
        SwapStep[] calldata steps,
        uint256 deadline,
        address receiver,
        Permit calldata permit_
    ) external nonReentrant returns (uint256 shares) {
        // Validar antes de llamar al token: nunca se llama a `permit` de un token que no está en lista blanca.
        if (!isStable[stable]) revert StableNotAllowed(stable);
        // La función ya es nonReentrant y la stable está en lista blanca: el aviso de reentrada no aplica.
        // Los bloques vacíos son intencionales: si `permit` falla se sigue (ver @dev).
        // forge-lint: disable-start(reentrancy-no-eth)
        // solhint-disable no-empty-blocks
        try IERC20Permit(stable)
            .permit(
                msg.sender, address(this), permit_.value, permit_.deadline, permit_.v, permit_.r, permit_.s
            ) {}
            catch {}
        // solhint-enable no-empty-blocks
        shares = _buy(stable, amountIn, minShares, steps, deadline, receiver);
        // forge-lint: disable-end(reentrancy-no-eth)
    }

    /// @dev Lógica común de `buy` y `buyWithPermit`.
    function _buy(
        address stable,
        uint256 amountIn,
        uint256 minShares,
        SwapStep[] calldata steps,
        uint256 deadline,
        address receiver
    ) internal returns (uint256 shares) {
        // 1. Validaciones
        if (paused || buyPaused) revert IsPaused();
        if (!isStable[stable]) revert StableNotAllowed(stable);
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _checkTradeSize(oracle.stableValueUsd(stable, amountIn));

        uint256[4] memory start = _snapshot(stable);

        // 2. Tomar la stable del usuario (se mide lo que realmente llegó)
        IERC20(stable).safeTransferFrom(msg.sender, address(this), amountIn);
        // Igualdad estricta intencional: debe llegar exactamente lo transferido (no se aceptan tokens con comisión).
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (IERC20(stable).balanceOf(address(this)) - start[2] != amountIn) revert BalanceMismatch(stable);

        // 3. Comisión → tesorería
        uint256 fee = Math.mulDiv(amountIn, buyFeeBps, BPS, Math.Rounding.Ceil);
        if (fee > 0) IERC20(stable).safeTransfer(treasury, fee);
        uint256 net = amountIn - fee;

        shares = _swapAndMint(stable, steps, net, start, minShares, receiver);
        _assertNoRetention(start, stable);

        // forge-lint: disable-next-line(reentrancy-events)
        emit Bought(msg.sender, receiver, stable, amountIn, fee, shares);
    }

    // ═══════════════════════════════ Venta ═══════════════════════════════

    /// @notice Vende BIETIX por una stablecoin.
    /// @param shares BIETIX a vender (el usuario debe haber aprobado al Router)
    /// @param stable stablecoin que quiere recibir
    /// @param minAmountOut mínimo neto que acepta recibir
    /// @param steps swaps WBTC → stable y WETH → stable
    /// @param deadline fecha límite de la transacción
    /// @param receiver quién recibe la stable (y lo que no se haya vendido)
    /// @return amountOut stable neta entregada
    function sell(
        uint256 shares,
        address stable,
        uint256 minAmountOut,
        SwapStep[] calldata steps,
        uint256 deadline,
        address receiver
    ) external nonReentrant returns (uint256 amountOut) {
        // 1. Validaciones
        if (paused || sellPaused) revert IsPaused();
        if (!isStable[stable]) revert StableNotAllowed(stable);
        if (block.timestamp > deadline) revert Expired();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        {
            (uint256 btcExp, uint256 ethExp) = VAULT.previewRedeem(shares);
            _checkTradeSize(oracle.basketValueUsd(btcExp, ethExp));
        }

        uint256[4] memory start = _snapshot(stable);

        // 2-3. Tomar los BIETIX y redimir In-Kind hacia el Router
        IERC20(address(VAULT)).safeTransferFrom(msg.sender, address(this), shares);
        // Lo recibido se mide por saldos en _swapAndPay; la función es nonReentrant.
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return, reentrancy-no-eth)
        VAULT.redeemInKind(shares, address(this));
        // slither-disable-end unused-return

        uint256 fee;
        (amountOut, fee) = _swapAndPay(stable, steps, start, minAmountOut, receiver);
        _assertNoRetention(start, stable);

        // forge-lint: disable-next-line(reentrancy-events)
        emit Sold(msg.sender, receiver, stable, shares, amountOut, fee);
    }

    /// @dev Pasos 4 a 9 de la compra, separados para mantener la función principal simple.
    function _swapAndMint(
        address stable,
        SwapStep[] calldata steps,
        uint256 net,
        uint256[4] memory start,
        uint256 minShares,
        address receiver
    ) internal returns (uint256 shares) {
        // 4. Swaps (solo la stable puede salir, y nunca más del neto)
        uint256 spent = _runSwaps(steps, stable, address(0), net, 0);

        // 5. Medir lo recibido
        uint256 btcGot = ASSET_BTC.balanceOf(address(this)) - start[0];
        uint256 ethGot = ASSET_ETH.balanceOf(address(this)) - start[1];

        // 6. Control contra oráculo (incluye sequencer, depeg del wrapper y de la stable)
        oracle.checkBuy(stable, spent, btcGot, ethGot);

        // 7. Calcular BIETIX a acuñar con lo realmente recibido (incluye la comisión In-Kind del vault)
        shares = _sharesFor(btcGot, ethGot);
        // slither-disable-next-line incorrect-equality
        if (shares < minShares || shares == 0) revert InsufficientOutput(shares, minShares);

        // 8. Acuñar en el vault como un usuario más (aprobación exacta y vuelta a 0)
        (uint256 b, uint256 e, uint256 fb, uint256 fe) = VAULT.previewMint(shares);
        ASSET_BTC.forceApprove(address(VAULT), b + fb);
        ASSET_ETH.forceApprove(address(VAULT), e + fe);
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return, reentrancy-no-eth)
        VAULT.mintInKind(shares, receiver);
        // slither-disable-end unused-return
        ASSET_BTC.forceApprove(address(VAULT), 0);
        ASSET_ETH.forceApprove(address(VAULT), 0);

        // 9. Devolver sobrantes al usuario
        _refund(ASSET_BTC, start[0], msg.sender);
        _refund(ASSET_ETH, start[1], msg.sender);
        _refund(IERC20(stable), start[2], msg.sender);
    }

    /// @dev Pasos 4 a 8 de la venta, separados para mantener la función principal simple.
    ///      Leer saldos y escribir el cupo después de los swaps es intencional: se mide lo efectivamente
    ///      vendido. `sell` es nonReentrant y los agregadores están en lista blanca.
    // slither-disable-start reentrancy-balance,reentrancy-benign
    function _swapAndPay(
        address stable,
        SwapStep[] calldata steps,
        uint256[4] memory start,
        uint256 minAmountOut,
        address receiver
    ) internal returns (uint256 amountOut, uint256 fee) {
        uint256 btcGot = ASSET_BTC.balanceOf(address(this)) - start[0];
        uint256 ethGot = ASSET_ETH.balanceOf(address(this)) - start[1];

        // 4. Swaps (solo WBTC/WETH pueden salir, y nunca más de lo redimido)
        _runSwaps(steps, address(ASSET_BTC), address(ASSET_ETH), btcGot, ethGot);
        uint256 btcSold = btcGot - (ASSET_BTC.balanceOf(address(this)) - start[0]);
        uint256 ethSold = ethGot - (ASSET_ETH.balanceOf(address(this)) - start[1]);
        // Una "venta" sin swaps sería un canje In-Kind que igual consumiría el cupo diario: se rechaza.
        // slither-disable-next-line incorrect-equality
        if (btcSold == 0 && ethSold == 0) revert InvalidStep();
        // El cupo de ventas se consume por lo realmente vendido, no por lo redimido.
        _consumeSellWindow(oracle.basketValueUsd(btcSold, ethSold));

        // 5. Medir la stable recibida y controlar contra oráculo
        uint256 gross = IERC20(stable).balanceOf(address(this)) - start[2];
        oracle.checkSell(stable, btcSold, ethSold, gross);

        // 6. Comisión → tesorería
        fee = Math.mulDiv(gross, sellFeeBps, BPS, Math.Rounding.Ceil);
        amountOut = gross - fee;

        // 7. Mínimo del usuario y pago
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        if (fee > 0) IERC20(stable).safeTransfer(treasury, fee);
        IERC20(stable).safeTransfer(receiver, amountOut);

        // 8. Lo que no se vendió vuelve al receptor
        _refund(ASSET_BTC, start[0], receiver);
        _refund(ASSET_ETH, start[1], receiver);
    }

    // slither-disable-end reentrancy-balance,reentrancy-benign

    // ═══════════════════════════════ Vistas ═══════════════════════════════

    /// @notice Cuántos BIETIX se pueden acuñar con estas cantidades, descontando la comisión In-Kind del vault.
    /// @param btcAmount WBTC disponible
    /// @param ethAmount WETH disponible
    /// @return BIETIX que se acuñarían
    function sharesFor(uint256 btcAmount, uint256 ethAmount) external view returns (uint256) {
        return _sharesFor(btcAmount, ethAmount);
    }

    /// @notice Cuánto USD queda disponible en la ventana de ventas actual.
    /// @return cupo disponible (USD, 18 decimales)
    function sellCapacityUsd() external view returns (uint256) {
        uint256 used = _currentSellUsed();
        return used >= sellLimitUsd ? 0 : sellLimitUsd - used;
    }

    // ═══════════════════════════════ Internas ═══════════════════════════════

    /// @dev Saldos del Router al empezar: WBTC, WETH, la stable y BIETIX (para la regla de no retención).
    function _snapshot(address stable) internal view returns (uint256[4] memory s) {
        s[0] = ASSET_BTC.balanceOf(address(this));
        s[1] = ASSET_ETH.balanceOf(address(this));
        s[2] = IERC20(stable).balanceOf(address(this));
        s[3] = VAULT.balanceOf(address(this));
    }

    /// @notice Ejecuta los swaps. Cada paso solo puede usar `tokenA` o `tokenB` y, en total, no más de
    ///         `maxA` / `maxB`. La aprobación es exacta y vuelve a 0 después de cada paso.
    /// @param steps pasos a ejecutar
    /// @param tokenA primer token permitido como entrada
    /// @param tokenB segundo token permitido (address(0) si hay uno solo)
    /// @param maxA máximo total de `tokenA` que puede salir
    /// @param maxB máximo total de `tokenB` que puede salir
    /// @return outA cantidad de `tokenA` que realmente salió del Router
    function _runSwaps(SwapStep[] calldata steps, address tokenA, address tokenB, uint256 maxA, uint256 maxB)
        internal
        returns (uint256 outA)
    {
        // Los saldos se leen antes y después de los swaps a propósito: así se mide lo que realmente salió.
        // slither-disable-start reentrancy-balance
        uint256 balA = IERC20(tokenA).balanceOf(address(this));
        uint256 balB = tokenB == address(0) ? 0 : IERC20(tokenB).balanceOf(address(this));
        (uint256 declaredA, uint256 declaredB) = _validateSteps(steps, tokenA, tokenB, maxA, maxB);

        // Bucle corto (normalmente 2 pasos) con llamadas a agregadores en lista blanca. La función que lo
        // llama es nonReentrant y lo recibido se mide por saldos después, así que es intencional.
        // slither-disable-start calls-loop
        // forge-lint: disable-start(calls-loop, reentrancy-no-eth)
        for (uint256 i; i < steps.length; ++i) {
            _execStep(steps[i]);
        }
        // forge-lint: disable-end(calls-loop, reentrancy-no-eth)
        // slither-disable-end calls-loop

        // Lo que realmente salió no puede superar lo declarado (un agregador no puede tomar de más).
        outA = _outflow(tokenA, balA);
        if (outA > declaredA) revert BalanceMismatch(tokenA);
        if (tokenB != address(0) && _outflow(tokenB, balB) > declaredB) revert BalanceMismatch(tokenB);
        // slither-disable-end reentrancy-balance
    }

    /// @dev Valida todos los pasos antes de ejecutar ninguno.
    // forge-lint: disable-start(require-revert-in-loop)
    function _validateSteps(
        SwapStep[] calldata steps,
        address tokenA,
        address tokenB,
        uint256 maxA,
        uint256 maxB
    ) internal view returns (uint256 spentA, uint256 spentB) {
        for (uint256 i; i < steps.length; ++i) {
            SwapStep calldata s = steps[i];
            if (!isSwapTarget[s.target]) revert TargetNotAllowed(s.target);
            if (s.amountIn == 0) revert InvalidStep();
            if (s.tokenIn == tokenA) {
                spentA += s.amountIn;
            } else if (tokenB != address(0) && s.tokenIn == tokenB) {
                spentB += s.amountIn;
            } else {
                revert InvalidStep();
            }
        }
        if (spentA > maxA || spentB > maxB) revert InvalidStep();
    }

    // forge-lint: disable-end(require-revert-in-loop)

    /// @dev Un swap: aprobación exacta → llamada al agregador → aprobación a 0.
    function _execStep(SwapStep calldata s) internal {
        IERC20(s.tokenIn).forceApprove(s.target, s.amountIn);
        // Se ejecuta dentro del bucle de _runSwaps (función nonReentrant); avisos de bucle/reentrada esperados.
        // forge-lint: disable-start(calls-loop, reentrancy-no-eth, require-revert-in-loop)
        // Llamada de bajo nivel intencional: `data` lo arma el agregador y `target` está en lista blanca.
        // solhint-disable avoid-low-level-calls
        // slither-disable-next-line low-level-calls,calls-loop
        (bool ok,) = s.target.call(s.data);
        // solhint-enable avoid-low-level-calls
        if (!ok) revert SwapFailed(s.target);
        // forge-lint: disable-end(calls-loop, reentrancy-no-eth, require-revert-in-loop)
        IERC20(s.tokenIn).forceApprove(s.target, 0);
    }

    /// @dev Cuánto salió de `token` desde `before` (0 si el saldo no bajó).
    function _outflow(address token, uint256 before) internal view returns (uint256) {
        uint256 nowBal = IERC20(token).balanceOf(address(this));
        return nowBal < before ? before - nowBal : 0;
    }

    /// @dev Mayor cantidad de BIETIX tal que activos + comisión In-Kind ≤ lo recibido.
    ///      Por qué alcanza la reserva de 2 unidades: con x = shares·unit/1e18 ≤ b·BPS/(BPS+fee) y f = fee/BPS,
    ///      el vault pide ceil(x) + ceil(ceil(x)·f) < x(1+f) + 2 + f ≤ b + 2 + f. Como f ≤ 0,01 y todo es entero,
    ///      lo pedido ≤ b + 2 = lo recibido. Lo comprueba `testFuzz_sharesFor_neverExceedsAmounts`.
    function _sharesFor(uint256 btcAmount, uint256 ethAmount) internal view returns (uint256 shares) {
        uint256 feeBps = VAULT.mintFeeBps();
        uint256 unitBtc = VAULT.UNIT_BTC();
        uint256 unitEth = VAULT.UNIT_ETH();
        // Se reservan 2 unidades mínimas de cada activo para cubrir los redondeos hacia arriba del vault.
        uint256 b = btcAmount > 2 ? btcAmount - 2 : 0;
        uint256 e = ethAmount > 2 ? ethAmount - 2 : 0;
        uint256 sB = Math.mulDiv(b, WAD * BPS, unitBtc * (BPS + feeBps));
        uint256 sE = Math.mulDiv(e, WAD * BPS, unitEth * (BPS + feeBps));
        shares = sB < sE ? sB : sE;
    }

    /// @dev Revierte si la operación vale más que `maxTradeUsd`.
    function _checkTradeSize(uint256 valueUsd) internal view {
        if (valueUsd > maxTradeUsd) revert TradeTooLarge(valueUsd, maxTradeUsd);
    }

    /// @dev Ventas acumuladas a hoy: lo vendido se descuenta linealmente a razón de `sellLimitUsd` cada 24 h.
    function _currentSellUsed() internal view returns (uint256) {
        uint256 decay = Math.mulDiv(sellLimitUsd, block.timestamp - sellUpdatedAt, SELL_WINDOW);
        return sellUsedUsd > decay ? sellUsedUsd - decay : 0;
    }

    /// @dev Suma `valueUsd` al cupo móvil de 24 h y revierte si lo supera.
    function _consumeSellWindow(uint256 valueUsd) internal {
        uint256 used = _currentSellUsed() + valueUsd;
        if (used > sellLimitUsd) revert SellLimitExceeded(used, sellLimitUsd);
        sellUsedUsd = used;
        sellUpdatedAt = block.timestamp;
    }

    /// @dev Devuelve a `to` lo que el Router tenga de `token` por encima de su saldo inicial.
    function _refund(IERC20 token, uint256 startBalance, address to) internal {
        uint256 bal = token.balanceOf(address(this));
        if (bal > startBalance) token.safeTransfer(to, bal - startBalance);
    }

    /// @dev Cada operación deja los saldos del Router exactamente como estaban (invariante I4).
    /// @dev Se compara contra el saldo inicial (no contra 0) para que una donación al Router no lo trabe.
    // forge-lint: disable-start(incorrect-strict-equality)
    function _assertNoRetention(uint256[4] memory start, address stable) internal view {
        if (ASSET_BTC.balanceOf(address(this)) != start[0]) revert BalanceMismatch(address(ASSET_BTC));
        if (ASSET_ETH.balanceOf(address(this)) != start[1]) revert BalanceMismatch(address(ASSET_ETH));
        if (IERC20(stable).balanceOf(address(this)) != start[2]) revert BalanceMismatch(stable);
        if (VAULT.balanceOf(address(this)) != start[3]) revert BalanceMismatch(address(VAULT));
    }

    // forge-lint: disable-end(incorrect-strict-equality)

    // ═══════════════════════ Pausas (sección 5.2) ═══════════════════════

    /// @notice Pausa compra y venta (guardián, inmediato). El canje In-Kind del vault sigue abierto.
    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit PauseChanged("all", true);
    }

    /// @notice Pausa solo las compras (guardián, inmediato).
    function pauseBuys() external onlyRole(GUARDIAN_ROLE) {
        buyPaused = true;
        emit PauseChanged("buy", true);
    }

    /// @notice Pausa solo las ventas (guardián, inmediato).
    function pauseSells() external onlyRole(GUARDIAN_ROLE) {
        sellPaused = true;
        emit PauseChanged("sell", true);
    }

    /// @notice Quita la pausa total (solo el Safe).
    function unpause() external onlyRole(UNPAUSER_ROLE) {
        paused = false;
        emit PauseChanged("all", false);
    }

    /// @notice Reanuda las compras (solo el Safe).
    function unpauseBuys() external onlyRole(UNPAUSER_ROLE) {
        buyPaused = false;
        emit PauseChanged("buy", false);
    }

    /// @notice Reanuda las ventas (solo el Safe).
    function unpauseSells() external onlyRole(UNPAUSER_ROLE) {
        sellPaused = false;
        emit PauseChanged("sell", false);
    }

    /// @notice El Safe le quita el rol a un guardián al instante. Nombrar uno nuevo requiere el Timelock.
    /// @param account guardián a quitar
    function revokeGuardian(address account) external onlyRole(UNPAUSER_ROLE) {
        _revokeRole(GUARDIAN_ROLE, account);
    }

    // ═══════════════ Listas blancas: quitar = guardián, agregar = Timelock ═══════════════

    /// @notice Agrega una stablecoin (Timelock). Tiene que estar configurada en el oráculo: si no, las compras
    ///         y ventas con ella revierten con `StableNotSupported`.
    /// @param token stablecoin
    function addStable(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addStable(token);
    }

    // Se usa también desde el constructor (bucle de configuración inicial): avisos de bucle esperados.
    // forge-lint: disable-start(require-revert-in-loop)

    /// @dev Agrega una stable. No puede ser un agregador, WBTC, WETH, el vault ni el Router.
    function _addStable(address token) internal {
        if (token == address(0)) revert ZeroAddress();
        // Una stable no puede ser un agregador, ni uno de los activos del índice, ni el propio token.
        if (
            isSwapTarget[token] || token == address(ASSET_BTC) || token == address(ASSET_ETH)
                || token == address(VAULT) || token == address(this)
        ) revert StableNotAllowed(token);
        isStable[token] = true;
        emit StableChanged(token, true);
    }

    // forge-lint: disable-end(require-revert-in-loop)

    /// @notice Quita una stablecoin (guardián, inmediato).
    /// @param token stablecoin
    function removeStable(address token) external onlyRole(GUARDIAN_ROLE) {
        isStable[token] = false;
        emit StableChanged(token, false);
    }

    /// @notice Agrega un agregador (Timelock).
    /// @param target contrato del agregador
    function addSwapTarget(address target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addSwapTarget(target);
    }

    // Se usa también desde el constructor (bucle de configuración inicial): avisos de bucle esperados.
    // forge-lint: disable-start(require-revert-in-loop)

    /// @dev Agrega un agregador. No puede ser el vault, WBTC, WETH, una stable, el Router ni el oráculo.
    function _addSwapTarget(address target) internal {
        // Nunca se permite llamar al vault ni a los activos directamente.
        if (
            target == address(0) || target == address(VAULT) || target == address(ASSET_BTC)
                || target == address(ASSET_ETH) || isStable[target] || target == address(this)
                || target == address(oracle)
        ) revert TargetNotAllowed(target);
        isSwapTarget[target] = true;
        emit SwapTargetChanged(target, true);
    }

    // forge-lint: disable-end(require-revert-in-loop)

    /// @notice Quita un agregador (guardián, inmediato).
    /// @param target contrato del agregador
    function removeSwapTarget(address target) external onlyRole(GUARDIAN_ROLE) {
        isSwapTarget[target] = false;
        emit SwapTargetChanged(target, false);
    }

    // ═══════════════ Límites: bajar = guardián, subir = Timelock ═══════════════

    /// @notice Baja el máximo por operación (guardián, inmediato).
    /// @param newMax máximo nuevo (USD, 18 decimales), menor al actual
    function decreaseMaxTrade(uint256 newMax) external onlyRole(GUARDIAN_ROLE) {
        if (newMax >= maxTradeUsd) revert NotLower();
        uint256 old = maxTradeUsd;
        maxTradeUsd = newMax;
        emit ParamChanged("maxTradeUsd", old, newMax);
    }

    /// @notice Sube el máximo por operación (Timelock).
    /// @param newMax máximo nuevo (USD, 18 decimales), mayor al actual
    function increaseMaxTrade(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMax <= maxTradeUsd) revert NotHigher();
        uint256 old = maxTradeUsd;
        maxTradeUsd = newMax;
        emit ParamChanged("maxTradeUsd", old, newMax);
    }

    /// @notice Baja el cupo de ventas de 24 h (guardián, inmediato).
    /// @param newLimit cupo nuevo (USD, 18 decimales), menor al actual
    function decreaseSellLimit(uint256 newLimit) external onlyRole(GUARDIAN_ROLE) {
        if (newLimit >= sellLimitUsd) revert NotLower();
        uint256 old = sellLimitUsd;
        sellLimitUsd = newLimit;
        emit ParamChanged("sellLimitUsd", old, newLimit);
    }

    /// @notice Sube el cupo de ventas de 24 h (Timelock).
    /// @param newLimit cupo nuevo (USD, 18 decimales), mayor al actual
    function increaseSellLimit(uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLimit <= sellLimitUsd) revert NotHigher();
        uint256 old = sellLimitUsd;
        sellLimitUsd = newLimit;
        emit ParamChanged("sellLimitUsd", old, newLimit);
    }

    // ═══════════════════════ Comisiones, oráculo, tesorería (Timelock) ═══════════════════════

    /// @notice Cambia la comisión de compra (Timelock, hasta MAX_FEE_BPS).
    /// @param newBps comisión nueva en bps
    function setBuyFee(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 old = buyFeeBps;
        buyFeeBps = newBps;
        emit ParamChanged("buyFeeBps", old, newBps);
    }

    /// @notice Cambia la comisión de venta (Timelock, hasta MAX_FEE_BPS).
    /// @param newBps comisión nueva en bps
    function setSellFee(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 old = sellFeeBps;
        sellFeeBps = newBps;
        emit ParamChanged("sellFeeBps", old, newBps);
    }

    /// @notice Cambia el oráculo (Timelock).
    /// @param newOracle oráculo nuevo
    function setOracle(OracleGuard newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        emit OracleChanged(address(oracle), address(newOracle));
        oracle = newOracle;
    }

    /// @notice Cambia la tesorería (Timelock).
    /// @param newTreasury tesorería nueva
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Rescata tokens enviados por error al Router (el Router nunca debería tener saldo).
    /// @dev Lo puede llamar el Timelock o el Safe. Todo va a tesorería.
    /// @param token token a rescatar
    function sweep(IERC20 token) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(UNPAUSER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, UNPAUSER_ROLE);
        }
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(treasury, amount);
        emit Swept(address(token), amount, treasury);
    }
}
