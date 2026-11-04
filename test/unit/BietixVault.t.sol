// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BietixVault} from "../../src/BietixVault.sol";
import {MockERC20, FeeOnTransferToken, ReentrantToken, IReenterTarget} from "../mocks/MockERC20.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

contract BietixVaultUnitTest is VaultTestBase {
    // ───────────────────────────── Constructor ─────────────────────────────

    function test_constructor_setsConfig() public view {
        assertEq(vault.name(), "Bietix");
        assertEq(vault.symbol(), "BIETIX");
        assertEq(address(vault.ASSET_BTC()), address(wbtc));
        assertEq(address(vault.ASSET_ETH()), address(weth));
        assertEq(vault.UNIT_BTC(), UNIT_BTC);
        assertEq(vault.UNIT_ETH(), UNIT_ETH);
        assertEq(vault.treasury(), treasury);
        assertEq(vault.mintFeeBps(), FEE_BPS);
        assertEq(vault.supplyCap(), CAP);
        assertEq(vault.defaultAdmin(), timelock);
        assertTrue(vault.hasRole(vault.UNPAUSER_ROLE(), safe));
        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), safe));
        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), guardian));
        assertFalse(vault.hasRole(vault.UNPAUSER_ROLE(), guardian));
    }

    function test_constructor_revertsOnZeroAddresses() public {
        BietixVault.Config memory c = _config(IERC20(address(wbtc)), IERC20(address(weth)));
        c.treasury = address(0);
        vm.expectRevert(BietixVault.ZeroAddress.selector);
        new BietixVault("D", "D", c);

        c = _config(IERC20(address(0)), IERC20(address(weth)));
        vm.expectRevert(BietixVault.ZeroAddress.selector);
        new BietixVault("D", "D", c);

        c = _config(IERC20(address(wbtc)), IERC20(address(weth)));
        c.guardian = address(0);
        vm.expectRevert(BietixVault.ZeroAddress.selector);
        new BietixVault("D", "D", c);

        c = _config(IERC20(address(wbtc)), IERC20(address(weth)));
        c.safe = address(0);
        vm.expectRevert(BietixVault.ZeroAddress.selector);
        new BietixVault("D", "D", c);
    }

    function test_constructor_revertsOnInvalidConfig() public {
        BietixVault.Config memory c = _config(IERC20(address(wbtc)), IERC20(address(wbtc)));
        vm.expectRevert(BietixVault.InvalidConfig.selector);
        new BietixVault("D", "D", c);

        c = _config(IERC20(address(wbtc)), IERC20(address(weth)));
        c.unitBtc = 0;
        vm.expectRevert(BietixVault.InvalidConfig.selector);
        new BietixVault("D", "D", c);

        c = _config(IERC20(address(wbtc)), IERC20(address(weth)));
        c.unitEth = 0;
        vm.expectRevert(BietixVault.InvalidConfig.selector);
        new BietixVault("D", "D", c);

        c = _config(IERC20(address(wbtc)), IERC20(address(weth)));
        c.mintFeeBps = 101;
        vm.expectRevert(BietixVault.FeeTooHigh.selector);
        new BietixVault("D", "D", c);
    }

    // ───────────────────────────── Acuñación ─────────────────────────────

    function test_mint_transfersExactAssetsAndFee() public {
        uint256 shares = 10e18; // 10 BIETIX = 0,001 BTC + 0,03 ETH
        _fundAndApprove(alice, shares);

        vm.expectEmit(true, true, false, true);
        emit BietixVault.Minted(alice, alice, shares, 100_000, 3e16, 50, 15e12);
        vm.prank(alice);
        (uint256 b, uint256 e) = vault.mintInKind(shares, alice);

        assertEq(b, 100_000);
        assertEq(e, 3e16);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(wbtc.balanceOf(address(vault)), 100_000);
        assertEq(weth.balanceOf(address(vault)), 3e16);
        // comisión 0,05% en los activos, directo a tesorería
        assertEq(wbtc.balanceOf(treasury), 50);
        assertEq(weth.balanceOf(treasury), 15e12);
        assertEq(wbtc.balanceOf(alice), 0);
        assertEq(weth.balanceOf(alice), 0);
    }

    function test_mint_toOtherReceiver() public {
        _fundAndApprove(alice, 1e18);
        vm.prank(alice);
        vault.mintInKind(1e18, bob);
        assertEq(vault.balanceOf(bob), 1e18);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_mint_roundsUpForUser() public {
        // 0,01 BIETIX + 1 unidad mínima: el BTC no divide exacto y se redondea hacia arriba
        uint256 shares = 1e16 + 1;
        (uint256 b, uint256 e) = vault.assetsForShares(shares, Math.Rounding.Ceil);
        (uint256 bf, uint256 ef) = vault.assetsForShares(shares, Math.Rounding.Floor);
        assertEq(bf, 100);
        assertEq(b, 101);
        assertGe(e, ef);

        _mint(alice, shares);
        assertEq(wbtc.balanceOf(address(vault)), 101);
    }

    function test_mint_zeroFee() public {
        vm.prank(timelock);
        vault.setMintFee(0);
        _mint(alice, 1e18);
        assertEq(wbtc.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), 0);
    }

    function test_mint_revertsBelowMinimum() public {
        _fundAndApprove(alice, 1e16);
        vm.prank(alice);
        vm.expectRevert(BietixVault.BelowMinimum.selector);
        vault.mintInKind(1e16 - 1, alice);
    }

    function test_mint_revertsWhenPaused() public {
        vm.prank(guardian);
        vault.pauseMint();
        _fundAndApprove(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(BietixVault.MintIsPaused.selector);
        vault.mintInKind(1e18, alice);
    }

    function test_mint_revertsAboveCap() public {
        vm.prank(guardian);
        vault.decreaseSupplyCap(5e18);
        _mint(alice, 5e18); // justo en el límite: OK
        _fundAndApprove(bob, 1e16);
        vm.prank(bob);
        vm.expectRevert(BietixVault.SupplyCapExceeded.selector);
        vault.mintInKind(1e16, bob);
    }

    function test_mint_revertsZeroReceiver() public {
        _fundAndApprove(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(BietixVault.ZeroAddress.selector);
        vault.mintInKind(1e18, address(0));
    }

    function test_mint_revertsWithoutApproval() public {
        wbtc.mint(alice, 1e8);
        weth.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.mintInKind(1e18, alice);
    }

    function test_mint_revertsWithFeeOnTransferAsset() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        BietixVault v = new BietixVault("D", "D", _config(IERC20(address(fot)), IERC20(address(weth))));
        fot.mint(alice, 1e8);
        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        fot.approve(address(v), type(uint256).max);
        weth.approve(address(v), type(uint256).max);
        vm.expectRevert(BietixVault.UnexpectedTransferAmount.selector);
        v.mintInKind(1e18, alice);
        vm.stopPrank();
    }

    // ───────────────────────────── Redención ─────────────────────────────

    function test_redeem_returnsExactAssets() public {
        _mint(alice, 10e18);
        vm.expectEmit(true, true, false, true);
        emit BietixVault.Redeemed(alice, alice, 4e18, 40_000, 12e15);
        vm.prank(alice);
        (uint256 b, uint256 e) = vault.redeemInKind(4e18, alice);
        assertEq(b, 40_000);
        assertEq(e, 12e15);
        assertEq(vault.balanceOf(alice), 6e18);
        assertEq(wbtc.balanceOf(alice), 40_000);
        assertEq(weth.balanceOf(alice), 12e15);
        assertEq(vault.totalSupply(), 6e18);
    }

    function test_redeem_toOtherReceiver() public {
        _mint(alice, 1e18);
        vm.prank(alice);
        vault.redeemInKind(1e18, bob);
        assertEq(wbtc.balanceOf(bob), UNIT_BTC);
        assertEq(weth.balanceOf(bob), UNIT_ETH);
    }

    function test_redeem_roundsDownForUser() public {
        _mint(alice, 1e18);
        // 1 unidad mínima de BIETIX vale fracciones de sat y de wei → recibe 0 (el vault no pierde nada)
        vm.prank(alice);
        (uint256 b, uint256 e) = vault.redeemInKind(1, alice);
        assertEq(b, 0);
        assertEq(e, 0);
        // 1,5e14 unidades = 1,5 sats → paga 1 sat (redondeo hacia abajo)
        vm.prank(alice);
        (b, e) = vault.redeemInKind(15e13, alice);
        assertEq(b, 1);
        assertEq(e, 45e10);
    }

    function test_redeem_worksWhileMintPaused() public {
        _mint(alice, 1e18);
        vm.prank(guardian);
        vault.pauseMint();
        vm.prank(alice);
        vault.redeemInKind(1e18, alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(wbtc.balanceOf(alice), UNIT_BTC);
    }

    function test_redeem_belowMintMinimumIsAllowed() public {
        _mint(alice, 1e18);
        vm.prank(alice);
        vault.redeemInKind(1e15, alice); // 0,001 BIETIX: menor al mínimo de acuñación, igual puede salir
        assertEq(vault.balanceOf(alice), 1e18 - 1e15);
    }

    function test_redeem_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(BietixVault.ZeroShares.selector);
        vault.redeemInKind(0, alice);
    }

    function test_redeem_revertsZeroReceiver() public {
        _mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(BietixVault.ZeroAddress.selector);
        vault.redeemInKind(1e18, address(0));
    }

    function test_redeem_revertsAboveBalance() public {
        _mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeemInKind(1e18 + 1, alice);
    }

    function test_redeem_cannotBurnSomeoneElsesTokens() public {
        _mint(alice, 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        vault.redeemInKind(1e18, attacker);
    }

    // ───────────────────────── Donaciones y ataques ─────────────────────────

    function test_donation_doesNotChangeValuePerToken() public {
        _mint(alice, 1e18);
        (uint256 b0, uint256 e0) = vault.previewRedeem(1e18);
        wbtc.mint(address(vault), 5e8); // alguien "dona" 5 BTC
        weth.mint(address(vault), 100e18);
        (uint256 b1, uint256 e1) = vault.previewRedeem(1e18);
        assertEq(b0, b1);
        assertEq(e0, e1);

        // un usuario nuevo tampoco se beneficia ni se perjudica
        _mint(bob, 1e18);
        vm.prank(bob);
        (uint256 b2, uint256 e2) = vault.redeemInKind(1e18, bob);
        assertEq(b2, UNIT_BTC);
        assertEq(e2, UNIT_ETH);
    }

    function test_reentrancy_isBlocked() public {
        ReentrantToken re = new ReentrantToken();
        BietixVault v = new BietixVault("D", "D", _config(IERC20(address(wbtc)), IERC20(address(re))));
        // fondear al token malicioso para que pueda intentar operar
        wbtc.mint(address(re), 1e8);
        re.mint(address(re), 1e18);
        vm.startPrank(address(re));
        wbtc.approve(address(v), type(uint256).max);
        re.approve(address(v), type(uint256).max);
        vm.stopPrank();

        wbtc.mint(alice, 1e8);
        re.mint(alice, 1e18);
        vm.startPrank(alice);
        wbtc.approve(address(v), type(uint256).max);
        re.approve(address(v), type(uint256).max);
        vm.stopPrank();

        re.arm(IReenterTarget(address(v)));
        vm.prank(alice);
        v.mintInKind(1e18, alice);

        assertTrue(re.reentered());
        assertFalse(re.reentrySucceeded());
    }

    // ─────────────────────────── Administración ───────────────────────────

    function test_pause_guardianAndSafeCan() public {
        vm.prank(guardian);
        vault.pauseMint();
        assertTrue(vault.mintPaused());
        vm.prank(safe);
        vault.unpauseMint();
        assertFalse(vault.mintPaused());
        vm.prank(safe);
        vault.pauseMint();
        assertTrue(vault.mintPaused());
    }

    function test_unpause_onlySafe() public {
        vm.prank(guardian);
        vault.pauseMint();
        address[3] memory notAllowed = [guardian, timelock, attacker];
        bytes32 role = vault.UNPAUSER_ROLE();
        for (uint256 i; i < notAllowed.length; i++) {
            vm.prank(notAllowed[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, notAllowed[i], role
                )
            );
            vault.unpauseMint();
        }
    }

    function test_pause_attackerCannot() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pauseMint();
    }

    function test_decreaseCap_guardianOnlyLowers() public {
        vm.prank(guardian);
        vault.decreaseSupplyCap(100e18);
        assertEq(vault.supplyCap(), 100e18);
        vm.prank(guardian);
        vm.expectRevert(BietixVault.CapNotLower.selector);
        vault.decreaseSupplyCap(200e18);
        vm.prank(attacker);
        vm.expectRevert();
        vault.decreaseSupplyCap(1);
    }

    function test_increaseCap_onlyTimelock() public {
        address[3] memory notAllowed = [guardian, safe, attacker];
        for (uint256 i; i < notAllowed.length; i++) {
            vm.prank(notAllowed[i]);
            vm.expectRevert();
            vault.increaseSupplyCap(CAP * 2);
        }
        vm.prank(timelock);
        vault.increaseSupplyCap(CAP * 2);
        assertEq(vault.supplyCap(), CAP * 2);
        vm.prank(timelock);
        vm.expectRevert(BietixVault.CapNotHigher.selector);
        vault.increaseSupplyCap(CAP);
    }

    function test_setMintFee_onlyTimelockAndCapped() public {
        address[3] memory notAllowed = [guardian, safe, attacker];
        for (uint256 i; i < notAllowed.length; i++) {
            vm.prank(notAllowed[i]);
            vm.expectRevert();
            vault.setMintFee(10);
        }
        vm.prank(timelock);
        vault.setMintFee(100);
        assertEq(vault.mintFeeBps(), 100);
        vm.prank(timelock);
        vm.expectRevert(BietixVault.FeeTooHigh.selector);
        vault.setMintFee(101);
    }

    function test_setTreasury_onlyTimelock() public {
        address[3] memory notAllowed = [guardian, safe, attacker];
        for (uint256 i; i < notAllowed.length; i++) {
            vm.prank(notAllowed[i]);
            vm.expectRevert();
            vault.setTreasury(bob);
        }
        vm.prank(timelock);
        vm.expectRevert(BietixVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
        vm.prank(timelock);
        vault.setTreasury(bob);
        assertEq(vault.treasury(), bob);
    }

    function test_revokeGuardian_bySafe() public {
        bytes32 g = vault.GUARDIAN_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        vault.revokeGuardian(guardian);
        vm.prank(guardian);
        vm.expectRevert();
        vault.revokeGuardian(guardian);

        vm.prank(safe);
        vault.revokeGuardian(guardian);
        assertFalse(vault.hasRole(g, guardian));
        vm.prank(guardian);
        vm.expectRevert();
        vault.pauseMint();
    }

    function test_grantGuardian_onlyTimelock() public {
        bytes32 g = vault.GUARDIAN_ROLE();
        vm.prank(safe);
        vm.expectRevert();
        vault.grantRole(g, bob);
        vm.prank(timelock);
        vault.grantRole(g, bob);
        assertTrue(vault.hasRole(g, bob));
    }

    function test_sweep_foreignToken() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(vault), 1000e6);
        vm.prank(safe);
        vault.sweep(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(treasury), 1000e6);

        usdc.mint(address(vault), 5e6);
        vm.prank(timelock);
        vault.sweep(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(treasury), 1005e6);
    }

    function test_sweep_cannotTouchCollateral() public {
        _mint(alice, 1e18);
        vm.startPrank(safe);
        vm.expectRevert(BietixVault.ProtectedAsset.selector);
        vault.sweep(IERC20(address(wbtc)));
        vm.expectRevert(BietixVault.ProtectedAsset.selector);
        vault.sweep(IERC20(address(weth)));
        vm.stopPrank();
        vm.prank(timelock);
        vm.expectRevert(BietixVault.ProtectedAsset.selector);
        vault.sweep(IERC20(address(wbtc)));
    }

    function test_sweep_unauthorized() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address[2] memory notAllowed = [guardian, attacker];
        for (uint256 i; i < notAllowed.length; i++) {
            vm.prank(notAllowed[i]);
            vm.expectRevert();
            vault.sweep(IERC20(address(usdc)));
        }
    }

    function test_adminTransfer_isTwoStepWithDelay() public {
        address newAdmin = makeAddr("newTimelock");
        vm.prank(timelock);
        vault.beginDefaultAdminTransfer(newAdmin);

        vm.prank(newAdmin);
        vm.expectRevert(); // todavía no pasó la espera
        vault.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();
        assertEq(vault.defaultAdmin(), newAdmin);
    }

    function test_adminTransfer_attackerCannotStart() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.beginDefaultAdminTransfer(attacker);
    }

    // ───────────────────────────── ERC20Permit ─────────────────────────────

    function test_permit_works() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        _mint(owner, 1e18);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                bob,
                1e18,
                vault.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vault.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(vault.allowance(owner, bob), 1e18);
    }
}
