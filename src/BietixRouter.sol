// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BietixVault} from "./BietixVault.sol";
import {OracleGuard} from "./OracleGuard.sol";

/// @title BietixRouter — compra y venta de BIETIX con stablecoins
/// @notice Convierte USDC/USDT ↔ WBTC/WETH mediante agregadores en lista blanca y llama al vault como
///         cualquier usuario. No retiene fondos entre transacciones y es reemplazable sin migrar nada.
/// @dev Ver Especificaciones Técnicas, secciones 1.4 y 3. Comisión total de compra = comisión del Router
///      + comisión In-Kind del vault (el Router paga la del vault como cualquier usuario).
contract BietixRouter is AccessControlDefaultAdminRules, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 100; // 1%
    uint256 public constant SELL_WINDOW = 1 days;

    /// @notice Un paso de swap: el Router aprueba `amountIn` de `tokenIn` a `target` y lo llama con `data`.
    /// @dev `target` debe estar en lista blanca y ser también quien toma los fondos (router del agregador).
    struct SwapStep {
        address target;
        address tokenIn;
        uint256 amountIn;
        bytes data;
    }

    BietixVault public immutable VAULT;
    IERC20 public immutable ASSET_BTC;
    IERC20 public immutable ASSET_ETH;

    OracleGuard public oracle;
    address public treasury;
    uint256 public buyFeeBps;
    uint256 public sellFeeBps;

    bool public paused;
    bool public buyPaused;
    bool public sellPaused;

    /// @notice Máximo por operación, en USD con 18 decimales.
    uint256 public maxTradeUsd;
    /// @notice Máximo de ventas a stablecoins por ventana de 24 h, en USD con 18 decimales.
    uint256 public sellLimitUsd;
    uint256 public sellWindowStart;
    uint256 public soldInWindowUsd;

    mapping(address => bool) public isStable;
    mapping(address => bool) public isSwapTarget;

    event Bought(
        address indexed user,
        address indexed receiver,
        address indexed stable,
        uint256 amountIn,
        uint256 fee,
        uint256 shares
    );
    event Sold(
        address indexed user,
        address indexed receiver,
        address indexed stable,
        uint256 shares,
        uint256 amountOut,
        uint256 fee
    );
    event PauseChanged(bytes32 indexed which, bool value);
    event StableChanged(address indexed token, bool allowed);
    event SwapTargetChanged(address indexed target, bool allowed);
    event ParamChanged(bytes32 indexed param, uint256 oldValue, uint256 newValue);
    event OracleChanged(address indexed oldOracle, address indexed newOracle);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event Swept(address indexed token, uint256 amount, address indexed to);

    error ZeroAddress();
    error ZeroAmount();
    error IsPaused();
    error StableNotAllowed(address token);
    error TargetNotAllowed(address target);
    error InvalidStep();
    error Expired();
    error TradeTooLarge(uint256 valueUsd, uint256 maxUsd);
    error SellLimitExceeded(uint256 soldUsd, uint256 limitUsd);
    error InsufficientOutput(uint256 got, uint256 min);
    error SwapFailed(address target);
    error FeeTooHigh();
    error NotLower();
    error NotHigher();
    error BalanceMismatch(address token);

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

    constructor(Config memory c) AccessControlDefaultAdminRules(c.adminTransferDelay, c.admin) {
        if (
            address(c.vault) == address(0) || address(c.oracle) == address(0) || c.safe == address(0)
                || c.guardian == address(0) || c.treasury == address(0)
        ) revert ZeroAddress();
        if (c.buyFeeBps > MAX_FEE_BPS || c.sellFeeBps > MAX_FEE_BPS) revert FeeTooHigh();

        VAULT = c.vault;
        ASSET_BTC = c.vault.ASSET_BTC();
        ASSET_ETH = c.vault.ASSET_ETH();
        oracle = c.oracle;
        treasury = c.treasury;
        buyFeeBps = c.buyFeeBps;
        sellFeeBps = c.sellFeeBps;
        maxTradeUsd = c.maxTradeUsd;
        sellLimitUsd = c.sellLimitUsd;
        sellWindowStart = block.timestamp;

        _grantRole(UNPAUSER_ROLE, c.safe);
        _grantRole(GUARDIAN_ROLE, c.safe);
        _grantRole(GUARDIAN_ROLE, c.guardian);

        // Configuración inicial en el mismo despliegue: así quien despliega nunca necesita permisos.
        for (uint256 i; i < c.stables.length; i++) {
            _addStable(c.stables[i]);
        }
        for (uint256 i; i < c.swapTargets.length; i++) {
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
    function buy(
        address stable,
        uint256 amountIn,
        uint256 minShares,
        SwapStep[] calldata steps,
        uint256 deadline,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
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
            uint256 valueUsd = oracle.basketValueUsd(btcExp, ethExp);
            _checkTradeSize(valueUsd);
            _consumeSellWindow(valueUsd);
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

    // ═══════════════════════════════ Vistas ═══════════════════════════════

    /// @notice Cuántos BIETIX se pueden acuñar con estas cantidades, descontando la comisión In-Kind del vault.
    function sharesFor(uint256 btcAmount, uint256 ethAmount) external view returns (uint256) {
        return _sharesFor(btcAmount, ethAmount);
    }

    /// @notice Cuánto USD queda disponible en la ventana de ventas actual.
    function sellCapacityUsd() external view returns (uint256) {
        if (block.timestamp >= sellWindowStart + SELL_WINDOW) return sellLimitUsd;
        return soldInWindowUsd >= sellLimitUsd ? 0 : sellLimitUsd - soldInWindowUsd;
    }

    // ═══════════════════════════════ Internas ═══════════════════════════════

    function _snapshot(address stable) internal view returns (uint256[4] memory s) {
        s[0] = ASSET_BTC.balanceOf(address(this));
        s[1] = ASSET_ETH.balanceOf(address(this));
        s[2] = IERC20(stable).balanceOf(address(this));
        s[3] = VAULT.balanceOf(address(this));
    }

    /// @dev Ejecuta los swaps. Cada paso solo puede usar `tokenA` o `tokenB` y, en total, no más de
    ///      `maxA` / `maxB`. La aprobación es exacta y vuelve a 0 después de cada paso.
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
        for (uint256 i; i < steps.length; i++) {
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
        for (uint256 i; i < steps.length; i++) {
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
        // slither-disable-next-line low-level-calls,calls-loop
        (bool ok,) = s.target.call(s.data);
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
        // slither-disable-next-line incorrect-equality
        if (shares == 0) return 0;
        (uint256 nb, uint256 ne, uint256 fb, uint256 fe) = VAULT.previewMint(shares);
        if (nb + fb > btcAmount || ne + fe > ethAmount) return 0; // no debería ocurrir; por las dudas
    }

    function _checkTradeSize(uint256 valueUsd) internal view {
        if (valueUsd > maxTradeUsd) revert TradeTooLarge(valueUsd, maxTradeUsd);
    }

    function _consumeSellWindow(uint256 valueUsd) internal {
        if (block.timestamp >= sellWindowStart + SELL_WINDOW) {
            sellWindowStart = block.timestamp;
            soldInWindowUsd = 0;
        }
        uint256 sold = soldInWindowUsd + valueUsd;
        if (sold > sellLimitUsd) revert SellLimitExceeded(sold, sellLimitUsd);
        soldInWindowUsd = sold;
    }

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

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit PauseChanged("all", true);
    }

    function pauseBuys() external onlyRole(GUARDIAN_ROLE) {
        buyPaused = true;
        emit PauseChanged("buy", true);
    }

    function pauseSells() external onlyRole(GUARDIAN_ROLE) {
        sellPaused = true;
        emit PauseChanged("sell", true);
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        paused = false;
        emit PauseChanged("all", false);
    }

    function unpauseBuys() external onlyRole(UNPAUSER_ROLE) {
        buyPaused = false;
        emit PauseChanged("buy", false);
    }

    function unpauseSells() external onlyRole(UNPAUSER_ROLE) {
        sellPaused = false;
        emit PauseChanged("sell", false);
    }

    function revokeGuardian(address account) external onlyRole(UNPAUSER_ROLE) {
        _revokeRole(GUARDIAN_ROLE, account);
    }

    // ═══════════════ Listas blancas: quitar = guardián, agregar = Timelock ═══════════════

    function addStable(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addStable(token);
    }

    // Se usa también desde el constructor (bucle de configuración inicial): avisos de bucle esperados.
    // forge-lint: disable-start(require-revert-in-loop)
    function _addStable(address token) internal {
        if (token == address(0)) revert ZeroAddress();
        isStable[token] = true;
        emit StableChanged(token, true);
    }
    // forge-lint: disable-end(require-revert-in-loop)

    function removeStable(address token) external onlyRole(GUARDIAN_ROLE) {
        isStable[token] = false;
        emit StableChanged(token, false);
    }

    function addSwapTarget(address target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addSwapTarget(target);
    }

    // Se usa también desde el constructor (bucle de configuración inicial): avisos de bucle esperados.
    // forge-lint: disable-start(require-revert-in-loop)
    function _addSwapTarget(address target) internal {
        // Nunca se permite llamar al vault ni a los activos directamente.
        if (
            target == address(0) || target == address(VAULT) || target == address(ASSET_BTC)
                || target == address(ASSET_ETH) || isStable[target]
        ) revert TargetNotAllowed(target);
        isSwapTarget[target] = true;
        emit SwapTargetChanged(target, true);
    }
    // forge-lint: disable-end(require-revert-in-loop)

    function removeSwapTarget(address target) external onlyRole(GUARDIAN_ROLE) {
        isSwapTarget[target] = false;
        emit SwapTargetChanged(target, false);
    }

    // ═══════════════ Límites: bajar = guardián, subir = Timelock ═══════════════

    function decreaseMaxTrade(uint256 newMax) external onlyRole(GUARDIAN_ROLE) {
        if (newMax >= maxTradeUsd) revert NotLower();
        uint256 old = maxTradeUsd;
        maxTradeUsd = newMax;
        emit ParamChanged("maxTradeUsd", old, newMax);
    }

    function increaseMaxTrade(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMax <= maxTradeUsd) revert NotHigher();
        uint256 old = maxTradeUsd;
        maxTradeUsd = newMax;
        emit ParamChanged("maxTradeUsd", old, newMax);
    }

    function decreaseSellLimit(uint256 newLimit) external onlyRole(GUARDIAN_ROLE) {
        if (newLimit >= sellLimitUsd) revert NotLower();
        uint256 old = sellLimitUsd;
        sellLimitUsd = newLimit;
        emit ParamChanged("sellLimitUsd", old, newLimit);
    }

    function increaseSellLimit(uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLimit <= sellLimitUsd) revert NotHigher();
        uint256 old = sellLimitUsd;
        sellLimitUsd = newLimit;
        emit ParamChanged("sellLimitUsd", old, newLimit);
    }

    // ═══════════════════════ Comisiones, oráculo, tesorería (Timelock) ═══════════════════════

    function setBuyFee(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 old = buyFeeBps;
        buyFeeBps = newBps;
        emit ParamChanged("buyFeeBps", old, newBps);
    }

    function setSellFee(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 old = sellFeeBps;
        sellFeeBps = newBps;
        emit ParamChanged("sellFeeBps", old, newBps);
    }

    function setOracle(OracleGuard newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        emit OracleChanged(address(oracle), address(newOracle));
        oracle = newOracle;
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Rescata tokens enviados por error al Router (el Router nunca debería tener saldo).
    function sweep(IERC20 token) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(UNPAUSER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, UNPAUSER_ROLE);
        }
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(treasury, amount);
        emit Swept(address(token), amount, treasury);
    }
}
