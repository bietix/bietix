// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Token de prueba con decimales configurables, acuñación libre y `permit` (EIP-2612).
contract MockERC20 is ERC20, ERC20Permit {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) ERC20Permit(n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Quita saldo a cualquiera, sin permiso: simula un token con rebase negativo o malicioso.
    function slash(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Token que se queda con un 1% en cada transferencia (no debe ser aceptado por el vault).
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee Token", "FOT", 8) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

interface IReenterTarget {
    function mintInKind(uint256 shares, address receiver) external returns (uint256, uint256);
    function redeemInKind(uint256 shares, address receiver) external returns (uint256, uint256);
}

/// @notice Token malicioso que intenta reentrar en el vault durante una transferencia.
contract ReentrantToken is MockERC20 {
    IReenterTarget public target;
    bool public armed;
    bool public reentered;
    bool public reentrySucceeded;

    constructor() MockERC20("Reentrant", "RE", 18) {}

    function arm(IReenterTarget t) external {
        target = t;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from != address(0) && to != address(0)) {
            armed = false;
            reentered = true;
            try target.redeemInKind(1, address(this)) {
                reentrySucceeded = true;
            } catch {}
            try target.mintInKind(1e16, address(this)) {
                reentrySucceeded = true;
            } catch {}
        }
    }
}
