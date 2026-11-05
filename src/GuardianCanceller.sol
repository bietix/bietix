// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title GuardianCanceller — veto del guardián sobre el Timelock, removible por el Safe
/// @notice El Timelock no le da el rol CANCELLER al guardián directamente: se lo da a este contrato,
///         que reenvía las cancelaciones del guardián actual. Así el Safe puede reemplazar o quitar al
///         guardián con una llamada directa (que no pasa por el Timelock y, por lo tanto, el guardián no
///         puede cancelar), pero con una espera de `CHANGE_DELAY`.
/// @dev Por qué la espera: si el Safe quedara comprometido, el guardián sigue vetando durante
///      `CHANGE_DELAY`, y a eso se suma la espera del Timelock. Los usuarios tienen todo ese tiempo para
///      salir con `redeemInKind`, que nunca se pausa.
contract GuardianCanceller {
    TimelockController public immutable TIMELOCK;
    address public immutable SAFE;
    uint256 public immutable CHANGE_DELAY;

    /// @notice Guardián actual (0 = sin guardián).
    address public guardian;
    address public pendingGuardian;
    /// @notice Momento desde el que se puede aplicar el cambio pendiente (0 = no hay cambio pendiente).
    uint256 public changeReadyAt;

    event GuardianCancelled(bytes32 indexed id);
    event GuardianChangeProposed(address indexed newGuardian, uint256 readyAt);
    event GuardianChangeCancelled(address indexed newGuardian);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);

    error ZeroAddress();
    error NotGuardian();
    error NotSafe();
    error NoPendingChange();
    error ChangeNotReady(uint256 readyAt);

    modifier onlySafe() {
        if (msg.sender != SAFE) revert NotSafe();
        _;
    }

    constructor(TimelockController timelock, address safe, address initialGuardian, uint256 changeDelay) {
        if (address(timelock) == address(0) || safe == address(0) || initialGuardian == address(0)) {
            revert ZeroAddress();
        }
        TIMELOCK = timelock;
        SAFE = safe;
        CHANGE_DELAY = changeDelay;
        guardian = initialGuardian;
        emit GuardianChanged(address(0), initialGuardian);
    }

    /// @notice El guardián cancela una operación programada en el Timelock.
    function cancel(bytes32 id) external {
        if (msg.sender != guardian) revert NotGuardian();
        emit GuardianCancelled(id);
        TIMELOCK.cancel(id);
    }

    /// @notice El Safe propone un guardián nuevo (address(0) = quitar el veto). Se aplica tras `CHANGE_DELAY`.
    // address(0) es válido a propósito: significa quitar el veto del guardián.
    // forge-lint: disable-next-line(missing-zero-check)
    // slither-disable-next-line missing-zero-check
    function proposeGuardian(address newGuardian) external onlySafe {
        pendingGuardian = newGuardian;
        changeReadyAt = block.timestamp + CHANGE_DELAY;
        emit GuardianChangeProposed(newGuardian, changeReadyAt);
    }

    /// @notice El Safe retira un cambio propuesto que todavía no se aplicó.
    function cancelGuardianChange() external onlySafe {
        if (changeReadyAt == 0) revert NoPendingChange();
        address p = pendingGuardian;
        delete pendingGuardian;
        delete changeReadyAt;
        emit GuardianChangeCancelled(p);
    }

    /// @notice Aplica el cambio pendiente. Cualquiera puede llamarla una vez cumplida la espera.
    function applyGuardianChange() external {
        uint256 readyAt = changeReadyAt;
        // 0 es el centinela de "sin cambio pendiente", no una comparación de tiempo.
        // slither-disable-next-line incorrect-equality
        if (readyAt == 0) revert NoPendingChange();
        if (block.timestamp < readyAt) revert ChangeNotReady(readyAt);
        address old = guardian;
        guardian = pendingGuardian;
        delete pendingGuardian;
        delete changeReadyAt;
        emit GuardianChanged(old, guardian);
    }

    /// @notice El guardián renuncia al veto (por ejemplo, si cree que su llave está comprometida). Inmediato.
    function resign() external {
        if (msg.sender != guardian) revert NotGuardian();
        delete guardian;
        emit GuardianChanged(msg.sender, address(0));
    }
}
