// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BietixVault — núcleo del índice BIETIX
/// @author Bietix
/// @notice Token ERC-20 y custodia en un solo contrato. Cada token (1e18 unidades mínimas)
///         representa siempre exactamente UNIT_BTC del activo BTC y UNIT_ETH del activo ETH.
/// @dev Diseño (ver Especificaciones Técnicas, secciones 1.3, 1.7 y 2.3):
///      - Inmutable: sin proxy, sin delegatecall, sin selfdestruct.
///      - Sin oráculos y sin swaps: solo acuña y quema contra activos reales.
///      - La redención In-Kind no se puede pausar ni bloquear por ningún rol.
///      - Ningún rol puede mover ASSET_BTC ni ASSET_ETH fuera del vault.
///      - Redondeo siempre a favor del vault: acuñar cobra hacia arriba, redimir paga hacia abajo.
contract BietixVault is ERC20, ERC20Permit, AccessControlDefaultAdminRules, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────── Roles ───────────────────────────────
    /// @notice Respuesta rápida: solo puede reducir riesgo (pausar, bajar el límite).
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Safe multisig: despausa, revoca guardianes y rescata tokens ajenos.
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");

    // ───────────────────────────── Constantes ─────────────────────────────
    /// @notice Unidades mínimas de un token entero (el token tiene 18 decimales).
    uint256 public constant SHARE_UNIT = 1e18;
    /// @notice Base de los puntos básicos: 10.000 bps = 100%.
    uint256 public constant BPS = 10_000;
    /// @notice Techo fijo de la comisión In-Kind de acuñación (1%).
    uint256 public constant MAX_MINT_FEE_BPS = 100;
    /// @notice Mínimo por acuñación (0,01 token) para evitar operaciones de polvo.
    uint256 public constant MIN_MINT_SHARES = 1e16;

    // ───────────────────────────── Inmutables ─────────────────────────────
    /// @notice Activo BTC del índice (WBTC). No cambia nunca.
    IERC20 public immutable ASSET_BTC;
    /// @notice Activo ETH del índice (WETH). No cambia nunca.
    IERC20 public immutable ASSET_ETH;
    /// @notice Unidades mínimas de ASSET_BTC por 1 token entero (ej. 10_000 = 0,0001 BTC con 8 decimales).
    uint256 public immutable UNIT_BTC;
    /// @notice Unidades mínimas de ASSET_ETH por 1 token entero (ej. 3e15 = 0,003 ETH con 18 decimales).
    uint256 public immutable UNIT_ETH;

    // ──────────────────────── Parámetros ajustables ───────────────────────
    /// @notice Dirección que recibe la comisión de acuñación In-Kind.
    address public treasury;
    /// @notice Comisión de acuñación In-Kind en bps, cobrada sobre cada activo (tope: MAX_MINT_FEE_BPS).
    uint256 public mintFeeBps;
    /// @notice Máximo de tokens en circulación (unidades mínimas).
    uint256 public supplyCap;
    /// @notice Si es true, no se puede acuñar. El canje In-Kind nunca se pausa.
    bool public mintPaused;

    // ────────────────────────────── Eventos ──────────────────────────────
    /// @notice Se acuñaron `shares` para `receiver` contra activos aportados por `caller`.
    /// @param caller quien aportó los activos
    /// @param receiver quien recibe los tokens
    /// @param shares tokens acuñados (unidades mínimas)
    /// @param btcIn BTC que quedó en el vault
    /// @param ethIn ETH que quedó en el vault
    /// @param feeBtc comisión en BTC enviada a tesorería
    /// @param feeEth comisión en ETH enviada a tesorería
    event Minted(
        address indexed caller,
        address indexed receiver,
        uint256 shares,
        uint256 btcIn,
        uint256 ethIn,
        uint256 feeBtc,
        uint256 feeEth
    );
    /// @notice Se quemaron `shares` de `caller` y se enviaron los activos a `receiver`.
    /// @param caller dueño de los tokens quemados
    /// @param receiver quien recibe los activos
    /// @param shares tokens quemados (unidades mínimas)
    /// @param btcOut BTC enviado
    /// @param ethOut ETH enviado
    event Redeemed(
        address indexed caller, address indexed receiver, uint256 shares, uint256 btcOut, uint256 ethOut
    );
    /// @notice Se pausó la acuñación.
    /// @param by cuenta que la pausó
    event MintPaused(address indexed by);
    /// @notice Se reanudó la acuñación.
    /// @param by cuenta que la reanudó
    event MintUnpaused(address indexed by);
    /// @notice Cambió el límite de emisión.
    /// @param oldCap límite anterior
    /// @param newCap límite nuevo
    event SupplyCapChanged(uint256 oldCap, uint256 newCap);
    /// @notice Cambió la comisión de acuñación In-Kind.
    /// @param oldFeeBps comisión anterior (bps)
    /// @param newFeeBps comisión nueva (bps)
    event MintFeeChanged(uint256 oldFeeBps, uint256 newFeeBps);
    /// @notice Cambió la tesorería.
    /// @param oldTreasury tesorería anterior
    /// @param newTreasury tesorería nueva
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    /// @notice Se rescataron tokens ajenos al índice enviados por error.
    /// @param token token rescatado
    /// @param amount cantidad
    /// @param to destino (tesorería)
    event Swept(address indexed token, uint256 amount, address indexed to);

    // ────────────────────────────── Errores ──────────────────────────────
    /// @notice Se pasó la dirección cero donde no se permite.
    error ZeroAddress();
    /// @notice Configuración de despliegue inválida (activos iguales o unidades en cero).
    error InvalidConfig();
    /// @notice La acuñación está pausada.
    error MintIsPaused();
    /// @notice La acuñación es menor que MIN_MINT_SHARES.
    error BelowMinimum();
    /// @notice Se pidió canjear 0 tokens.
    error ZeroShares();
    /// @notice La acuñación superaría el límite de emisión.
    error SupplyCapExceeded();
    /// @notice La comisión supera MAX_MINT_FEE_BPS.
    error FeeTooHigh();
    /// @notice `decreaseSupplyCap` con un valor que no es menor al actual.
    error CapNotLower();
    /// @notice `increaseSupplyCap` con un valor que no es mayor al actual.
    error CapNotHigher();
    /// @notice Se intentó rescatar WBTC o WETH, que son el colateral.
    error ProtectedAsset();
    /// @notice No llegó exactamente el monto pedido (token con comisión de transferencia).
    error UnexpectedTransferAmount();

    /// @notice Configuración de despliegue (agrupada en un struct para mantener el constructor simple).
    struct Config {
        IERC20 assetBtc; // WBTC (8 decimales)
        IERC20 assetEth; // WETH (18 decimales)
        uint256 unitBtc; // unidades de assetBtc por token entero
        uint256 unitEth; // unidades de assetEth por token entero
        address admin; // Timelock
        uint48 adminTransferDelay; // espera para transferir el rol de administrador (2 pasos)
        address safe; // Safe multisig: UNPAUSER + GUARDIAN
        address guardian; // billetera de respuesta rápida
        address treasury;
        uint256 mintFeeBps;
        uint256 supplyCap;
    }

    /// @notice Despliega el vault con activos y unidades fijas para siempre.
    /// @param name_ nombre del token
    /// @param symbol_ símbolo del token
    /// @param c configuración inicial (ver `Config`)
    constructor(string memory name_, string memory symbol_, Config memory c)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        AccessControlDefaultAdminRules(c.adminTransferDelay, c.admin)
    {
        if (
            address(c.assetBtc) == address(0) || address(c.assetEth) == address(0) || c.safe == address(0)
                || c.guardian == address(0) || c.treasury == address(0)
        ) revert ZeroAddress();
        if (address(c.assetBtc) == address(c.assetEth) || c.unitBtc == 0 || c.unitEth == 0) {
            revert InvalidConfig();
        }
        if (c.mintFeeBps > MAX_MINT_FEE_BPS) revert FeeTooHigh();

        ASSET_BTC = c.assetBtc;
        ASSET_ETH = c.assetEth;
        UNIT_BTC = c.unitBtc;
        UNIT_ETH = c.unitEth;

        treasury = c.treasury;
        mintFeeBps = c.mintFeeBps;
        supplyCap = c.supplyCap;

        _grantRole(UNPAUSER_ROLE, c.safe);
        _grantRole(GUARDIAN_ROLE, c.safe);
        _grantRole(GUARDIAN_ROLE, c.guardian);
    }

    // ═════════════════════════ Funciones de usuario ═════════════════════════

    /// @notice Acuña `shares` aportando el BTC/ETH exacto (redondeo hacia arriba) más la comisión In-Kind.
    /// @dev La comisión va directo a tesorería; nunca queda en el vault.
    /// @param shares tokens a acuñar (unidades mínimas, al menos MIN_MINT_SHARES)
    /// @param receiver quien recibe los tokens
    /// @return btcIn BTC que queda en el vault (sin contar la comisión)
    /// @return ethIn ETH que queda en el vault (sin contar la comisión)
    function mintInKind(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 btcIn, uint256 ethIn)
    {
        if (mintPaused) revert MintIsPaused();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares < MIN_MINT_SHARES) revert BelowMinimum();
        if (totalSupply() + shares > supplyCap) revert SupplyCapExceeded();

        (btcIn, ethIn) = assetsForShares(shares, Math.Rounding.Ceil);
        (uint256 feeBtc, uint256 feeEth) = _fees(btcIn, ethIn);

        // Efectos antes de las llamadas externas. Si alguna transferencia falla, todo se revierte.
        // El evento se emite antes de cualquier llamada externa y la función es nonReentrant;
        // el aviso del linter es un falso positivo.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Minted(msg.sender, receiver, shares, btcIn, ethIn, feeBtc, feeEth);
        _mint(receiver, shares);

        _pullExact(ASSET_BTC, msg.sender, btcIn);
        _pullExact(ASSET_ETH, msg.sender, ethIn);
        if (feeBtc > 0) ASSET_BTC.safeTransferFrom(msg.sender, treasury, feeBtc);
        if (feeEth > 0) ASSET_ETH.safeTransferFrom(msg.sender, treasury, feeEth);
    }

    /// @notice Quema `shares` del llamador y le envía a `receiver` el BTC/ETH correspondiente (redondeo hacia abajo).
    /// @dev No pausable, sin comisión y sin mínimo: la salida siempre está abierta.
    /// @param shares tokens a quemar (unidades mínimas)
    /// @param receiver quien recibe los activos
    /// @return btcOut BTC enviado
    /// @return ethOut ETH enviado
    function redeemInKind(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 btcOut, uint256 ethOut)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        (btcOut, ethOut) = assetsForShares(shares, Math.Rounding.Floor);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, receiver, shares, btcOut, ethOut);
        _burn(msg.sender, shares);

        if (btcOut > 0) ASSET_BTC.safeTransfer(receiver, btcOut);
        if (ethOut > 0) ASSET_ETH.safeTransfer(receiver, ethOut);
    }

    // ══════════════════════════════ Vistas ══════════════════════════════

    /// @notice Activos que respaldan `shares` tokens.
    /// @param shares cantidad de tokens (unidades mínimas)
    /// @param rounding Ceil para acuñar, Floor para canjear
    /// @return btc unidades mínimas de ASSET_BTC
    /// @return eth unidades mínimas de ASSET_ETH
    function assetsForShares(uint256 shares, Math.Rounding rounding)
        public
        view
        returns (uint256 btc, uint256 eth)
    {
        btc = Math.mulDiv(shares, UNIT_BTC, SHARE_UNIT, rounding);
        eth = Math.mulDiv(shares, UNIT_ETH, SHARE_UNIT, rounding);
    }

    /// @notice Total que el llamador debe aprobar para acuñar `shares` (activos + comisión).
    /// @param shares tokens a acuñar (unidades mínimas)
    /// @return btcIn BTC que queda en el vault
    /// @return ethIn ETH que queda en el vault
    /// @return feeBtc comisión en BTC (se aprueba aparte de btcIn)
    /// @return feeEth comisión en ETH (se aprueba aparte de ethIn)
    function previewMint(uint256 shares)
        external
        view
        returns (uint256 btcIn, uint256 ethIn, uint256 feeBtc, uint256 feeEth)
    {
        (btcIn, ethIn) = assetsForShares(shares, Math.Rounding.Ceil);
        (feeBtc, feeEth) = _fees(btcIn, ethIn);
    }

    /// @notice Activos que se recibirían al canjear `shares`.
    /// @param shares tokens a canjear (unidades mínimas)
    /// @return btcOut BTC a recibir
    /// @return ethOut ETH a recibir
    function previewRedeem(uint256 shares) external view returns (uint256 btcOut, uint256 ethOut) {
        return assetsForShares(shares, Math.Rounding.Floor);
    }

    // ═══════════════════════ Administración (acotada) ═══════════════════════

    /// @notice Reduce riesgo → inmediato (guardián o Safe).
    function pauseMint() external onlyRole(GUARDIAN_ROLE) {
        mintPaused = true;
        emit MintPaused(msg.sender);
    }

    /// @notice Reabrir es deliberado → solo el Safe.
    function unpauseMint() external onlyRole(UNPAUSER_ROLE) {
        mintPaused = false;
        emit MintUnpaused(msg.sender);
    }

    /// @notice Bajar el límite reduce riesgo → inmediato.
    /// @param newCap límite nuevo, menor al actual
    function decreaseSupplyCap(uint256 newCap) external onlyRole(GUARDIAN_ROLE) {
        if (newCap >= supplyCap) revert CapNotLower();
        emit SupplyCapChanged(supplyCap, newCap);
        supplyCap = newCap;
    }

    /// @notice Subir el límite aumenta riesgo → solo el administrador (Timelock).
    /// @param newCap límite nuevo, mayor al actual
    function increaseSupplyCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCap <= supplyCap) revert CapNotHigher();
        emit SupplyCapChanged(supplyCap, newCap);
        supplyCap = newCap;
    }

    /// @notice Cambia la comisión de acuñación In-Kind (solo el Timelock, hasta MAX_MINT_FEE_BPS).
    /// @param newFeeBps comisión nueva en bps
    function setMintFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_MINT_FEE_BPS) revert FeeTooHigh();
        uint256 oldFee = mintFeeBps;
        mintFeeBps = newFeeBps;
        emit MintFeeChanged(oldFee, newFeeBps);
    }

    /// @notice Cambia la tesorería (solo el Timelock).
    /// @param newTreasury tesorería nueva
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice El Safe puede quitarle el rol a un guardián al instante (por ejemplo, si su llave se filtró).
    ///         Nombrar uno nuevo requiere el administrador (Timelock).
    /// @param account guardián a quitar
    function revokeGuardian(address account) external onlyRole(UNPAUSER_ROLE) {
        _revokeRole(GUARDIAN_ROLE, account);
    }

    /// @notice Rescata tokens enviados por error. Nunca puede tocar el colateral.
    /// @dev Lo puede llamar el Timelock o el Safe. Todo va a tesorería.
    /// @param token token a rescatar (no puede ser ASSET_BTC ni ASSET_ETH)
    function sweep(IERC20 token) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(UNPAUSER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, UNPAUSER_ROLE);
        }
        if (address(token) == address(ASSET_BTC) || address(token) == address(ASSET_ETH)) {
            revert ProtectedAsset();
        }
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(treasury, amount);
        emit Swept(address(token), amount, treasury);
    }

    // ═════════════════════════════ Internas ═════════════════════════════

    /// @dev Comisión In-Kind sobre cada activo, redondeada hacia arriba (a favor del protocolo).
    function _fees(uint256 btc, uint256 eth) internal view returns (uint256 feeBtc, uint256 feeEth) {
        uint256 fee = mintFeeBps;
        if (fee == 0) return (0, 0);
        feeBtc = Math.mulDiv(btc, fee, BPS, Math.Rounding.Ceil);
        feeEth = Math.mulDiv(eth, fee, BPS, Math.Rounding.Ceil);
    }

    /// @dev Exige que llegue exactamente `amount` (protege contra tokens con comisión de transferencia).
    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        // Igualdad estricta intencional: debe llegar exactamente lo pedido, ni más ni menos.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (token.balanceOf(address(this)) - before != amount) revert UnexpectedTransferAmount();
    }
}
