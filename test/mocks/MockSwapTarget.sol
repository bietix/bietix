// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Agregador falso. Toma `amountIn` de quien llama y entrega `amountOut` (acuñado) a `to`.
///         Tiene modos maliciosos para las pruebas de ataque.
contract MockSwapTarget {
    enum Mode {
        Normal,
        Steal, // toma los fondos y no entrega nada
        TakeMore, // intenta tomar más de lo aprobado
        Fail, // revierte
        Reenter // intenta reentrar en el Router
    }

    Mode public mode;
    address public reenterTarget;
    bytes public reenterData;
    bool public reenterSucceeded;

    function setMode(Mode m) external {
        mode = m;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    /// @notice Si se configura, después de tomar `tokenIn` le quita 1 unidad extra al llamador (token malicioso).
    address public slashToken;

    function setSlashToken(address t) external {
        slashToken = t;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address to)
        external
    {
        if (slashToken == tokenIn) MockERC20(tokenIn).slash(msg.sender, 1);
        if (mode == Mode.Fail) revert("swap fallido");
        if (mode == Mode.TakeMore) {
            require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn + 1), "tf");
            return;
        }
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "tf");
        if (mode == Mode.Steal) return;
        if (mode == Mode.Reenter) {
            (bool ok,) = reenterTarget.call(reenterData);
            reenterSucceeded = ok;
        }
        MockERC20(tokenOut).mint(to, amountOut);
    }
}

/// @notice Token tipo USDT: no permite cambiar una aprobación distinta de 0 sin ponerla antes en 0.
contract MockUSDT is MockERC20 {
    constructor() MockERC20("Tether USD", "USDT", 6) {}

    function approve(address spender, uint256 value) public override returns (bool) {
        require(value == 0 || allowance(msg.sender, spender) == 0, "USDT: aprobar 0 primero");
        return super.approve(spender, value);
    }
}
