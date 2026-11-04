// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// @notice Invariantes del sistema (sección 6.4 de las especificaciones) para el núcleo.
contract DuoxVaultInvariantTest is VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, wbtc, weth, timelock, safe, guardian);
        targetContract(address(handler));
    }

    /// I1 — El token siempre está totalmente respaldado.
    function invariant_I1_fullyBacked() public view {
        (uint256 needB, uint256 needE) = vault.assetsForShares(vault.totalSupply(), Math.Rounding.Floor);
        assertGe(wbtc.balanceOf(address(vault)), needB, "falta BTC");
        assertGe(weth.balanceOf(address(vault)), needE, "falta ETH");
    }

    /// I2 — Todo holder puede redimir su saldo completo, en cualquier estado (incluso con la acuñación pausada).
    function invariant_I2_everyoneCanExit() public {
        uint256 snap = vm.snapshotState();
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            address a = handler.actors(i);
            uint256 bal = vault.balanceOf(a);
            if (bal == 0) continue;
            (uint256 expB, uint256 expE) = vault.previewRedeem(bal);
            uint256 b0 = wbtc.balanceOf(a);
            uint256 e0 = weth.balanceOf(a);
            vm.prank(a);
            vault.redeemInKind(bal, a); // si esto revierte, la invariante falla
            assertEq(wbtc.balanceOf(a) - b0, expB);
            assertEq(weth.balanceOf(a) - e0, expE);
        }
        assertEq(vault.totalSupply(), 0, "quedo supply sin dueno");
        vm.revertToState(snap);
    }

    /// I3 — La suma de saldos es igual al supply total.
    function invariant_I3_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            sum += vault.balanceOf(handler.actors(i));
        }
        assertEq(sum, vault.totalSupply());
    }

    /// I7 — Ninguna acuñación deja el supply por encima del límite.
    function invariant_I7_capRespected() public view {
        assertFalse(handler.mintExceededCap());
    }

    /// I8 — Los parámetros quedan dentro de sus techos y nadie no autorizado los cambió.
    function invariant_I8_paramsBounded() public view {
        assertLe(vault.mintFeeBps(), vault.MAX_MINT_FEE_BPS());
        assertEq(vault.treasury(), treasury);
        assertEq(vault.defaultAdmin(), timelock);
        assertFalse(vault.hasRole(vault.GUARDIAN_ROLE(), address(0xBAD)));
    }

    /// I9 — La definición del índice nunca cambia.
    function invariant_I9_unitsImmutable() public view {
        assertEq(vault.UNIT_BTC(), UNIT_BTC);
        assertEq(vault.UNIT_ETH(), UNIT_ETH);
        assertEq(address(vault.ASSET_BTC()), address(wbtc));
        assertEq(address(vault.ASSET_ETH()), address(weth));
    }
}
