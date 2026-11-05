// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {BietixRouter} from "../../src/BietixRouter.sol";
import {SystemTestBase} from "../utils/SystemTestBase.sol";

/// @notice Estrés: muchos usuarios comprando y vendiendo con montos grandes, cambios de precio,
///         transferencias entre usuarios y una salida masiva al final. Después de cada etapa el vault
///         tiene que seguir 100% respaldado y el Router sin saldos ni aprobaciones abiertas.
contract StressTest is SystemTestBase {
    uint256 internal constant USERS = 60;

    function _user(uint256 i) internal pure returns (address) {
        return address(uint160(0xB1E7100 + i));
    }

    function _assertBacked() internal view {
        uint256 supply = vault.totalSupply();
        assertGe(wbtc.balanceOf(address(vault)), supply * vault.UNIT_BTC() / 1e18, "falta WBTC");
        assertGe(weth.balanceOf(address(vault)), supply * vault.UNIT_ETH() / 1e18, "falta WETH");
    }

    function test_stress_manyUsersBuySellTransferAndMassExit() public {
        vm.startPrank(timelock);
        router.increaseSellLimit(10_000_000e18); // el cupo no es lo que se prueba acá
        vault.increaseSupplyCap(100_000_000e18);
        vm.stopPrank();

        // 1. Compras: montos de $100 a $25.000 (el máximo por operación), alternando USDC y USDT
        uint256[] memory shares = new uint256[](USERS);
        for (uint256 i; i < USERS; ++i) {
            address stable = i % 2 == 0 ? address(usdc) : address(usdt);
            uint256 amount = (100 + (i * 7_919) % 24_900) * 1e6;
            shares[i] = _buy(_user(i), stable, amount);
            assertGt(shares[i], 0);
        }
        _assertBacked();
        _assertRouterClean();

        // 2. El precio se mueve (BTC +15%, ETH -10%) y la mitad de los usuarios transfiere tokens a otro
        btcFeed.setAnswer(92_000e8);
        ethFeed.setAnswer(2_400e8);
        for (uint256 i; i < USERS / 2; ++i) {
            uint256 half = shares[i] / 2;
            vm.prank(_user(i));
            vault.transfer(_user(USERS - 1 - i), half);
            shares[i] -= half;
            shares[USERS - 1 - i] += half;
        }

        // 3. Ventas: un tercio vende todo por el Router
        for (uint256 i; i < USERS; i += 3) {
            address u = _user(i);
            BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares[i], 10);
            vm.startPrank(u);
            vault.approve(address(router), shares[i]);
            router.sell(shares[i], address(usdc), 0, steps, block.timestamp, u);
            vm.stopPrank();
            shares[i] = 0;
        }
        _assertBacked();
        _assertRouterClean();

        // 4. Salida masiva: el Router queda pausado (escenario de emergencia) y todos canjean In-Kind
        vm.prank(guardian);
        router.pause();
        vm.prank(guardian);
        vault.pauseMint();
        for (uint256 i; i < USERS; ++i) {
            uint256 bal = vault.balanceOf(_user(i));
            assertEq(bal, shares[i], "saldo inesperado");
            if (bal == 0) continue;
            vm.prank(_user(i));
            vault.redeemInKind(bal, _user(i));
        }
        assertEq(vault.totalSupply(), 0, "quedaron tokens");
        _assertBacked();
        _assertRouterClean();
    }
}
