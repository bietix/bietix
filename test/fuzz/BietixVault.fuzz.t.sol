// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Pruebas con valores aleatorios (sección 6.5 de las especificaciones).
contract BietixVaultFuzzTest is VaultTestBase {
    uint256 internal constant MAX_SHARES = 1_000_000e18;

    /// Acuñar y redimir enseguida nunca devuelve más de lo aportado (invariante I6).
    function testFuzz_roundTrip_neverProfits(uint256 shares, uint256 feeBps) public {
        shares = bound(shares, 1e16, MAX_SHARES);
        feeBps = bound(feeBps, 0, 100);
        vm.prank(timelock);
        vault.setMintFee(feeBps);

        (uint256 b, uint256 e, uint256 fb, uint256 fe) = vault.previewMint(shares);
        _mint(alice, shares);
        vm.prank(alice);
        (uint256 bo, uint256 eo) = vault.redeemInKind(shares, alice);

        assertLe(bo, b + fb, "gano BTC");
        assertLe(eo, e + fe, "gano ETH");
        assertEq(vault.balanceOf(alice), 0);
    }

    /// Partir una redención en dos nunca da más que hacerla de una sola vez.
    function testFuzz_splitRedeem_neverBetter(uint256 shares, uint256 part) public {
        shares = bound(shares, 2e16, MAX_SHARES);
        part = bound(part, 1, shares - 1);
        _mint(alice, shares);
        (uint256 bWhole, uint256 eWhole) = vault.previewRedeem(shares);

        vm.startPrank(alice);
        (uint256 b1, uint256 e1) = vault.redeemInKind(part, alice);
        (uint256 b2, uint256 e2) = vault.redeemInKind(shares - part, alice);
        vm.stopPrank();

        assertLe(b1 + b2, bWhole);
        assertLe(e1 + e2, eWhole);
    }

    /// El redondeo siempre favorece al vault: lo que entra ≥ lo que sale para la misma cantidad.
    function testFuzz_rounding_favorsVault(uint256 shares) public view {
        shares = bound(shares, 0, type(uint128).max);
        (uint256 bc, uint256 ec) = vault.assetsForShares(shares, Math.Rounding.Ceil);
        (uint256 bf, uint256 ef) = vault.assetsForShares(shares, Math.Rounding.Floor);
        assertGe(bc, bf);
        assertGe(ec, ef);
        assertLe(bc - bf, 1);
        assertLe(ec - ef, 1);
    }

    /// La comisión nunca supera el techo y se redondea a favor del protocolo.
    function testFuzz_fee_boundedAndRoundedUp(uint256 shares, uint256 feeBps) public {
        shares = bound(shares, 1e16, MAX_SHARES);
        feeBps = bound(feeBps, 0, 100);
        vm.prank(timelock);
        vault.setMintFee(feeBps);
        (uint256 b, uint256 e, uint256 fb, uint256 fe) = vault.previewMint(shares);
        assertLe(fb, Math.mulDiv(b, 100, 10_000, Math.Rounding.Ceil));
        assertLe(fe, Math.mulDiv(e, 100, 10_000, Math.Rounding.Ceil));
        assertGe(fb * 10_000, b * feeBps);
        assertGe(fe * 10_000, e * feeBps);
    }

    /// Después de cualquier secuencia de dos acuñaciones y una redención, el vault sigue respaldado.
    function testFuzz_backing_afterOperations(uint256 s1, uint256 s2, uint256 r) public {
        s1 = bound(s1, 1e16, MAX_SHARES / 2);
        s2 = bound(s2, 1e16, MAX_SHARES / 2);
        _mint(alice, s1);
        _mint(bob, s2);
        r = bound(r, 1, s1);
        vm.prank(alice);
        vault.redeemInKind(r, alice);

        uint256 supply = vault.totalSupply();
        (uint256 needB, uint256 needE) = vault.assetsForShares(supply, Math.Rounding.Floor);
        assertGe(wbtc.balanceOf(address(vault)), needB);
        assertGe(weth.balanceOf(address(vault)), needE);
    }

    /// Un parámetro de comisión fuera del techo siempre revierte.
    function testFuzz_setMintFee_aboveCapReverts(uint256 feeBps) public {
        feeBps = bound(feeBps, 101, type(uint256).max);
        vm.prank(timelock);
        vm.expectRevert();
        vault.setMintFee(feeBps);
    }
}
