// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title GuardianCanceller — veto del guardián sobre el Timelock, removible por el Safe
/// @author Bietix
/// @notice El Timelock no le da el rol CANCELLER al guardián directamente: se lo da a este contrato,
///         que reenvía las cancelaciones del guardián actual. Así el Safe puede reemplazar o quitar al
///         guardián con una llamada directa (que no pasa por el Timelock y, por lo tanto, el guardián no
///         puede cancelar), pero con una espera de `CHANGE_DELAY`.
/// @dev Por qué la espera: si el Safe quedara comprometido, el guardián sigue vetando durante
///      `CHANGE_DELAY`, y a eso se suma la espera del Timelock. Los usuarios tienen todo ese tiempo para
///      salir con `redeemInKind`, que nunca se pausa.
contract GuardianCanceller {
    /// @notice Timelock sobre el que este contrato tiene el rol CANCELLER.
    TimelockController public immutable TIMELOCK;
    /// @notice Safe multisig: único que puede proponer o retirar un cambio de guardián.
    address public immutable SAFE;
    /// @notice Espera (segundos) entre proponer un guardián nuevo y poder aplicarlo.
    uint256 public immutable CHANGE_DELAY;

    /// @notice Guardián actual (0 = sin guardián).
    address public guardian;
    /// @notice Guardián propuesto que todavía no se aplicó (puede ser address(0) = quitar el veto).
    address public pendingGuardian;
    /// @notice Momento desde el que se puede aplicar el cambio pendiente (0 = no hay cambio pendiente).
    uint256 public changeReadyAt;

    /// @notice El guardián canceló una operación del Timelock.
    /// @param id identificador de la operación cancelada
    event GuardianCancelled(bytes32 indexed id);
    /// @notice El Safe propuso un guardián nuevo.
    /// @param newGuardian guardián propuesto (address(0) = quitar el veto)
    /// @param readyAt momento desde el que se puede aplicar
    event GuardianChangeProposed(address indexed newGuardian, uint256 readyAt);
    /// @notice El Safe retiró el cambio propuesto.
    /// @param newGuardian guardián que se había propuesto
    event GuardianChangeCancelled(address indexed newGuardian);
    /// @notice Cambió el guardián (por cambio aplicado, renuncia o despliegue).
    /// @param oldGuardian guardián anterior
    /// @param newGuardian guardián nuevo
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);

    /// @notice Se pasó la dirección cero en el constructor.
    error ZeroAddress();
    /// @notice Quien llama no es el guardián actual.
    error NotGuardian();
    /// @notice Quien llama no es el Safe.
    error NotSafe();
    /// @notice No hay un cambio de guardián pendiente.
    error NoPendingChange();
    /// @notice Todavía no pasó la espera del cambio.
    /// @param readyAt momento desde el que se puede aplicar
    error ChangeNotReady(uint256 readyAt);

    /// @dev Solo el Safe.
    modifier onlySafe() {
        if (msg.sender != SAFE) revert NotSafe();
        _;
    }

    /// @notice Crea el veto con su guardián inicial.
    /// @param timelock Timelock a proteger
    /// @param safe Safe multisig que administra al guardián
    /// @param initialGuardian guardián inicial
    /// @param changeDelay espera para cambiar de guardián (debe ser al menos la del Timelock)
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
    /// @param id identificador de la operación (`TimelockController.hashOperation`)
    function cancel(bytes32 id) external {
        if (msg.sender != guardian) revert NotGuardian();
        emit GuardianCancelled(id);
        TIMELOCK.cancel(id);
    }

    // address(0) es válido a propósito en proposeGuardian: significa quitar el veto del guardián.
    // slither-disable-start missing-zero-check
    // forge-lint: disable-start(missing-zero-check)

    /// @notice El Safe propone un guardián nuevo (address(0) = quitar el veto). Se aplica tras `CHANGE_DELAY`.
    /// @dev Una propuesta nueva reemplaza a la anterior y reinicia la espera. Cumplida la espera, cualquiera
    ///      puede aplicar el cambio: para arrepentirse hay que llamar a `cancelGuardianChange` antes.
    /// @param newGuardian guardián propuesto
    function proposeGuardian(address newGuardian) external onlySafe {
        pendingGuardian = newGuardian;
        changeReadyAt = block.timestamp + CHANGE_DELAY;
        emit GuardianChangeProposed(newGuardian, changeReadyAt);
    }

    // forge-lint: disable-end(missing-zero-check)
    // slither-disable-end missing-zero-check

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
