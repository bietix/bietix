// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BietixRouter} from "../../src/BietixRouter.sol";
import {BietixVault} from "../../src/BietixVault.sol";
import {OracleGuard} from "../../src/OracleGuard.sol";
import {noFeeds, noStables, noAddresses} from "../utils/Empty.sol";
import {MockSwapTarget} from "../mocks/MockSwapTarget.sol";
import {FeeOnTransferToken} from "../mocks/MockERC20.sol";
import {SystemTestBase} from "../utils/SystemTestBase.sol";

/// @notice Pruebas del Router (secciones 1.4, 3 y 5 de las especificaciones).
contract BietixRouterTest is SystemTestBase {
    // ═══════════════════════════════ Compra ═══════════════════════════════

    function test_buy_happyPath() public {
        uint256 amountIn = 1_000e6;
        _fund(alice, address(usdc), amountIn);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), amountIn, 10);

        vm.prank(alice);
        uint256 shares = router.buy(address(usdc), amountIn, 1, steps, block.timestamp, alice);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(treasury), 2.5e6, "comision 0,25%");
        assertEq(usdc.balanceOf(alice), 0);
        _assertRouterClean();

        // valor recibido ≈ 1.000 − 0,25% Router − 0,05% vault − 0,10% slippage − polvo
        uint256 worth = guard.indexPriceUsd(UNIT_BTC, UNIT_ETH) * shares / 1e18;
        assertGt(worth, 994e18);
        assertLt(worth, 1_000e18);
    }

    function test_buy_toOtherReceiverAndRefundsDust() public {
        uint256 amountIn = 1_000e6;
        _fund(alice, address(usdc), amountIn);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), amountIn, 0);
        vm.prank(alice);
        uint256 shares = router.buy(address(usdc), amountIn, 0, steps, block.timestamp, bob);
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.balanceOf(alice), 0);
        // el polvo de WBTC/WETH que no alcanzó para un BIETIX entero vuelve a quien pagó
        assertTrue(wbtc.balanceOf(alice) > 0 || weth.balanceOf(alice) > 0);
        _assertRouterClean();
    }

    function test_buy_refundsUnspentStable() public {
        uint256 amountIn = 1_000e6;
        _fund(alice, address(usdc), amountIn);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), amountIn, 0);
        // se usa un poco menos del neto en el swap de ETH
        uint256 lessIn = steps[1].amountIn - 1e6;
        steps[1] = _step(address(usdc), lessIn, address(weth), lessIn * 1e12 * 1e18 / guard.ethUsd());
        vm.prank(alice);
        router.buy(address(usdc), amountIn, 0, steps, block.timestamp, alice);
        assertEq(usdc.balanceOf(alice), 1e6);
        _assertRouterClean();
    }

    function test_buy_withUSDT() public {
        uint256 shares = _buy(alice, address(usdt), 5_000e6);
        assertGt(shares, 0);
        // segunda compra: la aprobación tipo USDT (exige volver a 0) no debe trabar el Router
        uint256 shares2 = _buy(bob, address(usdt), 5_000e6);
        assertGt(shares2, 0);
        _assertRouterClean();
    }

    function test_buy_revertsWhenPaused() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        vm.prank(guardian);
        router.pause();
        vm.prank(alice);
        vm.expectRevert(BietixRouter.IsPaused.selector);
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);

        vm.prank(safe);
        router.unpause();
        vm.prank(guardian);
        router.pauseBuys();
        vm.prank(alice);
        vm.expectRevert(BietixRouter.IsPaused.selector);
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
    }

    function test_buy_revertsOnBasicValidation() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        address dai = makeAddr("DAI");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.StableNotAllowed.selector, dai));
        router.buy(dai, 1_000e6, 0, steps, block.timestamp, alice);
        vm.expectRevert(BietixRouter.Expired.selector);
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp - 1, alice);
        vm.expectRevert(BietixRouter.ZeroAmount.selector);
        router.buy(address(usdc), 0, 0, steps, block.timestamp, alice);
        vm.expectRevert(BietixRouter.ZeroAddress.selector);
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, address(0));
        vm.stopPrank();
    }

    function test_buy_revertsOnMinShares() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        vm.prank(alice);
        vm.expectRevert();
        router.buy(address(usdc), 1_000e6, 1_000e18, steps, block.timestamp, alice);
    }

    function test_buy_revertsOnBadExecution() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 150); // 1,5% peor
        vm.prank(alice);
        vm.expectRevert();
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
    }

    function test_buy_revertsWhenTradeTooLarge() public {
        _fund(alice, address(usdc), 25_001e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 25_001e6, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.TradeTooLarge.selector, 25_001e18, MAX_TRADE));
        router.buy(address(usdc), 25_001e6, 0, steps, block.timestamp, alice);
    }

    function test_buy_blockedWhenWrapperDepegged() public {
        _fund(alice, address(usdc), 1_000e6);
        wrapFeed.setAnswer(0.97e8);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        vm.prank(alice);
        vm.expectRevert(OracleGuard.WrapperDepegged.selector);
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
    }

    function test_buy_blockedWhenStableDepegged() public {
        _fund(alice, address(usdt), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdt), 1_000e6, 0);
        usdtFeed.setAnswer(0.97e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.StablePriceTooLow.selector, address(usdt)));
        router.buy(address(usdt), 1_000e6, 0, steps, block.timestamp, alice);
    }

    function test_buy_blockedWhenSequencerDown() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        seqFeed.setAnswer(1);
        vm.prank(alice);
        vm.expectRevert(OracleGuard.SequencerDown.selector);
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
    }

    function test_buy_revertsOnInvalidSteps() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);

        // destino fuera de la lista blanca
        BietixRouter.SwapStep[] memory bad = _copy(steps);
        bad[0].target = attacker;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.TargetNotAllowed.selector, attacker));
        router.buy(address(usdc), 1_000e6, 0, bad, block.timestamp, alice);

        // token de entrada que no es la stable
        bad = _copy(steps);
        bad[0].tokenIn = address(wbtc);
        vm.prank(alice);
        vm.expectRevert(BietixRouter.InvalidStep.selector);
        router.buy(address(usdc), 1_000e6, 0, bad, block.timestamp, alice);

        // gastar más del neto (después de comisión)
        bad = _copy(steps);
        bad[1].amountIn = steps[1].amountIn + 10e6;
        vm.prank(alice);
        vm.expectRevert(BietixRouter.InvalidStep.selector);
        router.buy(address(usdc), 1_000e6, 0, bad, block.timestamp, alice);

        // monto cero
        bad = _copy(steps);
        bad[0].amountIn = 0;
        vm.prank(alice);
        vm.expectRevert(BietixRouter.InvalidStep.selector);
        router.buy(address(usdc), 1_000e6, 0, bad, block.timestamp, alice);
    }

    // ═══════════════════════════════ Venta ═══════════════════════════════

    function test_sell_happyPath() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 10);

        vm.startPrank(alice);
        vault.approve(address(router), shares);
        uint256 out = router.sell(shares, address(usdc), 1, steps, block.timestamp, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), out);
        assertGt(usdc.balanceOf(treasury), treasuryBefore);
        // ida y vuelta: ~1.000 − 0,30% compra − 0,30% venta − 0,2% slippage − polvo
        assertGt(out, 990e6);
        assertLt(out, 1_000e6);
        _assertRouterClean();
        assertGt(router.sellUsedUsd(), 0);
    }

    function test_sell_partialSwapRefundsUnsold() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        BietixRouter.SwapStep[] memory onlyBtc = new BietixRouter.SwapStep[](1);
        onlyBtc[0] = steps[0];
        uint256 wethBefore = weth.balanceOf(alice);
        (, uint256 e) = vault.previewRedeem(shares);

        vm.startPrank(alice);
        vault.approve(address(router), shares);
        router.sell(shares, address(usdc), 0, onlyBtc, block.timestamp, alice);
        vm.stopPrank();

        assertEq(weth.balanceOf(alice) - wethBefore, e, "el WETH no vendido vuelve al usuario");
        _assertRouterClean();
    }

    function test_sell_revertsWhenPaused() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        vm.prank(alice);
        vault.approve(address(router), shares);

        vm.prank(guardian);
        router.pauseSells();
        vm.prank(alice);
        vm.expectRevert(BietixRouter.IsPaused.selector);
        router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);

        vm.prank(safe);
        router.unpauseSells();
        vm.prank(guardian);
        router.pause();
        vm.prank(alice);
        vm.expectRevert(BietixRouter.IsPaused.selector);
        router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);
    }

    function test_sell_worksWhileBuysPausedAndWrapperDepegged() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        vm.prank(guardian);
        router.pauseBuys();
        wrapFeed.setAnswer(0.95e8);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        uint256 out = router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);
        vm.stopPrank();
        assertGt(out, 0);
    }

    function test_sell_revertsOnValidation() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        address dai = makeAddr("DAI");
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.StableNotAllowed.selector, dai));
        router.sell(shares, dai, 0, steps, block.timestamp, alice);
        vm.expectRevert(BietixRouter.Expired.selector);
        router.sell(shares, address(usdc), 0, steps, block.timestamp - 1, alice);
        vm.expectRevert(BietixRouter.ZeroAmount.selector);
        router.sell(0, address(usdc), 0, steps, block.timestamp, alice);
        vm.expectRevert(BietixRouter.ZeroAddress.selector);
        router.sell(shares, address(usdc), 0, steps, block.timestamp, address(0));
        vm.expectRevert(); // mínimo imposible
        router.sell(shares, address(usdc), 1_000e6, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    function test_sell_revertsOnBadExecution() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 150);
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        vm.expectRevert();
        router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    function test_sell_revertsOnStepUsingOtherToken() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        steps[0].tokenIn = address(usdc);
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        vm.expectRevert(BietixRouter.InvalidStep.selector);
        router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    function test_sell_revertsWhenSellingMoreThanRedeemed() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        steps[1].amountIn += 1;
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        vm.expectRevert(BietixRouter.InvalidStep.selector);
        router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    function test_sell_dailyLimit() public {
        vm.prank(guardian);
        router.decreaseSellLimit(1_500e18);
        uint256 s1 = _buy(alice, address(usdc), 1_000e6);
        uint256 s2 = _buy(bob, address(usdc), 1_000e6);

        _sellAll(alice, s1); // ~$997 vendidos: OK

        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), s2, 0);
        vm.startPrank(bob);
        vault.approve(address(router), s2);
        vm.expectRevert(); // superaría $1.500 en la ventana
        router.sell(s2, address(usdc), 0, steps, block.timestamp, bob);
        vm.stopPrank();
        assertLt(router.sellCapacityUsd(), 600e18);

        // la salida In-Kind directa sigue disponible sin límite
        vm.prank(bob);
        vault.redeemInKind(s2, bob);
        assertEq(vault.balanceOf(bob), 0);

        // pasada la ventana de 24 h, el límite se renueva
        vm.warp(block.timestamp + 1 days);
        seqFeed.setStartedAt(block.timestamp - 2 hours);
        btcFeed.setAnswer(80_000e8);
        ethFeed.setAnswer(2_667e8);
        wrapFeed.setAnswer(1e8);
        usdcFeed.setAnswer(1e8);
        assertEq(router.sellCapacityUsd(), 1_500e18);
    }

    function test_sell_revertsWhenTradeTooLarge() public {
        vm.prank(timelock);
        router.increaseSellLimit(100_000e18);
        uint256 s1 = _buy(alice, address(usdc), 20_000e6);
        uint256 s2 = _buy(alice, address(usdc), 20_000e6);
        uint256 total = s1 + s2;
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), total, 0);
        vm.startPrank(alice);
        vault.approve(address(router), total);
        vm.expectRevert(); // ~$39.800 > máximo de $25.000
        router.sell(total, address(usdc), 0, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    // ═══════════════════════════════ Ataques ═══════════════════════════════

    function test_attack_targetStealsFunds() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        dex.setMode(MockSwapTarget.Mode.Steal);
        vm.prank(alice);
        vm.expectRevert(); // no llega WBTC/WETH → el control contra oráculo o el mínimo revierten
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
        assertEq(usdc.balanceOf(alice), 1_000e6, "el usuario no pierde nada");
    }

    function test_attack_targetTakesMoreThanApproved() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        dex.setMode(MockSwapTarget.Mode.TakeMore);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.SwapFailed.selector, address(dex)));
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
    }

    function test_attack_targetFails() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        dex.setMode(MockSwapTarget.Mode.Fail);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.SwapFailed.selector, address(dex)));
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
    }

    function test_attack_reentrancyBlocked() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 0);
        BietixRouter.SwapStep[] memory inner = new BietixRouter.SwapStep[](0);
        dex.setReenter(
            address(router),
            abi.encodeCall(BietixRouter.buy, (address(usdc), 1, 0, inner, block.timestamp, address(dex)))
        );
        dex.setMode(MockSwapTarget.Mode.Reenter);
        vm.prank(alice);
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
        assertFalse(dex.reenterSucceeded(), "la reentrada debe fallar");
        _assertRouterClean();
    }

    function test_attack_cannotWhitelistVaultOrAssets() public {
        address[4] memory forbidden = [address(vault), address(wbtc), address(weth), address(usdc)];
        vm.startPrank(timelock);
        for (uint256 i; i < forbidden.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(BietixRouter.TargetNotAllowed.selector, forbidden[i]));
            router.addSwapTarget(forbidden[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.TargetNotAllowed.selector, address(0)));
        router.addSwapTarget(address(0));
        vm.stopPrank();
    }

    function test_attack_donationDoesNotBrickRouter() public {
        usdc.mint(address(router), 123e6);
        wbtc.mint(address(router), 1e8);
        weth.mint(address(router), 1e18);
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        assertGt(shares, 0);
        // la donación sigue ahí (no se la lleva el usuario) y se puede rescatar
        assertEq(usdc.balanceOf(address(router)), 123e6);
        vm.prank(safe);
        router.sweep(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(treasury), 123e6 + 2.5e6);
    }

    function test_attack_tokenDonationDoesNotBrickRouter() public {
        uint256 s1 = _buy(bob, address(usdc), 100e6);
        vm.prank(bob);
        assertTrue(vault.transfer(address(router), s1)); // alguien "dona" BIETIX al Router
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        _sellAll(alice, shares);
        assertEq(vault.balanceOf(address(router)), s1, "la donacion queda intacta y se puede rescatar");
    }

    function test_attack_sellWithoutApprovalFails() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        vm.prank(attacker);
        vm.expectRevert();
        router.sell(shares, address(usdc), 0, steps, block.timestamp, attacker);
    }

    // ═══════════════════════════════ Emergencias ═══════════════════════════════

    function test_emergency_inKindExitWorksWhenEverythingElseIsDown() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        vm.startPrank(guardian);
        router.pause();
        vault.pauseMint();
        vm.stopPrank();
        seqFeed.setAnswer(1); // Arbitrum caído según el oráculo
        btcFeed.setRevert(true); // Chainlink caído

        vm.prank(alice);
        (uint256 b, uint256 e) = vault.redeemInKind(shares, alice);
        assertGt(b, 0);
        assertGt(e, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ═══════════════════════════════ Permisos ═══════════════════════════════

    function test_admin_pauses() public {
        address[2] memory notAllowed = [attacker, timelock];
        for (uint256 i; i < notAllowed.length; i++) {
            vm.startPrank(notAllowed[i]);
            vm.expectRevert();
            router.pause();
            vm.expectRevert();
            router.pauseBuys();
            vm.expectRevert();
            router.pauseSells();
            vm.stopPrank();
        }
        vm.startPrank(guardian);
        router.pause();
        router.pauseBuys();
        router.pauseSells();
        vm.expectRevert();
        router.unpause();
        vm.expectRevert();
        router.unpauseBuys();
        vm.expectRevert();
        router.unpauseSells();
        vm.stopPrank();
        vm.startPrank(safe);
        router.unpause();
        router.unpauseBuys();
        router.unpauseSells();
        vm.stopPrank();
        assertFalse(router.paused() || router.buyPaused() || router.sellPaused());
    }

    function test_admin_lists() public {
        address x = makeAddr("x");
        vm.prank(guardian);
        vm.expectRevert();
        router.addStable(x);
        vm.prank(guardian);
        vm.expectRevert();
        router.addSwapTarget(x);
        vm.prank(timelock);
        vm.expectRevert(BietixRouter.ZeroAddress.selector);
        router.addStable(address(0));

        vm.prank(guardian);
        router.removeStable(address(usdt));
        assertFalse(router.isStable(address(usdt)));
        vm.prank(guardian);
        router.removeSwapTarget(address(dex));
        assertFalse(router.isSwapTarget(address(dex)));
        vm.prank(attacker);
        vm.expectRevert();
        router.removeStable(address(usdc));
    }

    function test_admin_limits() public {
        vm.startPrank(guardian);
        router.decreaseMaxTrade(10_000e18);
        vm.expectRevert(BietixRouter.NotLower.selector);
        router.decreaseMaxTrade(20_000e18);
        vm.expectRevert();
        router.increaseMaxTrade(30_000e18);
        router.decreaseSellLimit(10_000e18);
        vm.expectRevert(BietixRouter.NotLower.selector);
        router.decreaseSellLimit(20_000e18);
        vm.expectRevert();
        router.increaseSellLimit(30_000e18);
        vm.stopPrank();

        vm.startPrank(timelock);
        router.increaseMaxTrade(30_000e18);
        vm.expectRevert(BietixRouter.NotHigher.selector);
        router.increaseMaxTrade(30_000e18);
        router.increaseSellLimit(30_000e18);
        vm.expectRevert(BietixRouter.NotHigher.selector);
        router.increaseSellLimit(1);
        vm.stopPrank();
        assertEq(router.maxTradeUsd(), 30_000e18);
        assertEq(router.sellLimitUsd(), 30_000e18);
    }

    function test_admin_feesOracleTreasury() public {
        address[3] memory notAllowed = [guardian, safe, attacker];
        for (uint256 i; i < notAllowed.length; i++) {
            vm.startPrank(notAllowed[i]);
            vm.expectRevert();
            router.setBuyFee(10);
            vm.expectRevert();
            router.setSellFee(10);
            vm.expectRevert();
            router.setOracle(guard);
            vm.expectRevert();
            router.setTreasury(bob);
            vm.stopPrank();
        }
        vm.startPrank(timelock);
        router.setBuyFee(100);
        router.setSellFee(0);
        vm.expectRevert(BietixRouter.FeeTooHigh.selector);
        router.setBuyFee(101);
        vm.expectRevert(BietixRouter.FeeTooHigh.selector);
        router.setSellFee(101);
        vm.expectRevert(BietixRouter.ZeroAddress.selector);
        router.setOracle(OracleGuard(address(0)));
        vm.expectRevert(BietixRouter.ZeroAddress.selector);
        router.setTreasury(address(0));
        router.setTreasury(bob);
        router.setOracle(guard);
        vm.stopPrank();
        assertEq(router.treasury(), bob);
        assertEq(router.buyFeeBps(), 100);
    }

    function test_admin_revokeGuardianAndSweep() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.revokeGuardian(guardian);
        vm.prank(safe);
        router.revokeGuardian(guardian);
        vm.prank(guardian);
        vm.expectRevert();
        router.pause();

        usdc.mint(address(router), 5e6);
        vm.prank(guardian);
        vm.expectRevert();
        router.sweep(IERC20(address(usdc)));
        vm.prank(timelock);
        router.sweep(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(treasury), 5e6);
    }

    function test_constructor_validation() public {
        BietixRouter.Config memory c = BietixRouter.Config({
            vault: vault,
            oracle: guard,
            admin: timelock,
            adminTransferDelay: 2 days,
            safe: safe,
            guardian: guardian,
            treasury: treasury,
            buyFeeBps: 25,
            sellFeeBps: 30,
            maxTradeUsd: MAX_TRADE,
            sellLimitUsd: SELL_LIMIT,
            stables: noAddresses(),
            swapTargets: noAddresses()
        });
        c.treasury = address(0);
        vm.expectRevert(BietixRouter.ZeroAddress.selector);
        new BietixRouter(c);
        c.treasury = treasury;
        c.vault = BietixVault(address(0));
        vm.expectRevert();
        new BietixRouter(c);
        c.vault = vault;
        c.sellFeeBps = 101;
        vm.expectRevert(BietixRouter.FeeTooHigh.selector);
        new BietixRouter(c);
        c.sellFeeBps = 30;
        c.buyFeeBps = 101;
        vm.expectRevert(BietixRouter.FeeTooHigh.selector);
        new BietixRouter(c);
    }

    function test_sharesFor_view() public view {
        assertEq(router.sharesFor(0, 0), 0);
        assertEq(router.sharesFor(2, 1e18), 0, "con polvo de BTC no alcanza");
        uint256 s = router.sharesFor(1e8, 30e18); // 1 BTC + 30 ETH = 10.000 BIETIX antes de comision
        assertGt(s, 9_990e18);
        assertLt(s, 10_000e18);
        (uint256 b, uint256 e, uint256 fb, uint256 fe) = vault.previewMint(s);
        assertLe(b + fb, 1e8);
        assertLe(e + fe, 30e18);
    }

    function test_buy_rejectsFeeOnTransferStable() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        vm.startPrank(timelock);
        guard.setStable(address(fot), 8, usdcFeed, 90_000, 0.5e18, 1.5e18);
        router.addStable(address(fot));
        vm.stopPrank();
        fot.mint(alice, 1_000e8);
        vm.startPrank(alice);
        fot.approve(address(router), 1_000e8);
        BietixRouter.SwapStep[] memory none = new BietixRouter.SwapStep[](0);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.BalanceMismatch.selector, address(fot)));
        router.buy(address(fot), 1_000e8, 0, none, block.timestamp, alice);
        vm.stopPrank();
    }

    function test_sellCapacity_zeroWhenLimitLoweredBelowSold() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        _sellAll(alice, shares);
        vm.prank(guardian);
        router.decreaseSellLimit(100e18);
        assertEq(router.sellCapacityUsd(), 0);
    }

    function test_sell_windowResetsAfterADay() public {
        vm.prank(guardian);
        router.decreaseSellLimit(1_500e18);
        uint256 s1 = _buy(alice, address(usdc), 1_000e6);
        uint256 s2 = _buy(bob, address(usdc), 1_000e6);
        _sellAll(alice, s1);

        uint256 later = vm.getBlockTimestamp() + 1 days;
        vm.warp(later);
        seqFeed.setStartedAt(later - 2 hours);
        btcFeed.setAnswer(80_000e8);
        ethFeed.setAnswer(2_667e8);
        wrapFeed.setAnswer(1e8);
        usdcFeed.setAnswer(1e8);
        _sellAll(bob, s2); // en la ventana nueva vuelve a haber cupo
        assertLt(router.sellUsedUsd(), 1_000e18);
        assertEq(router.sellUpdatedAt(), later);
    }

    // ─────────────────── Regresiones de la revisión interna ───────────────────

    /// M-1: una "venta" sin swaps (= canje In-Kind por el Router) ya no puede consumir el cupo diario.
    function test_sell_emptyStepsRevertsAndDoesNotConsumeWindow() public {
        uint256 shares = _buy(attacker, address(usdc), 10_000e6);
        uint256 before = router.sellCapacityUsd();
        BietixRouter.SwapStep[] memory none = new BietixRouter.SwapStep[](0);
        vm.startPrank(attacker);
        vault.approve(address(router), shares);
        vm.expectRevert(BietixRouter.InvalidStep.selector);
        router.sell(shares, address(usdc), 0, none, block.timestamp, attacker);
        vm.stopPrank();
        assertEq(router.sellCapacityUsd(), before);
    }

    /// M-1: el cupo se consume por lo vendido, no por lo redimido (vender solo la parte BTC cuenta la mitad).
    function test_sell_windowChargesOnlySoldValue() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory all = _sellSteps(address(usdc), shares, 0);
        BietixRouter.SwapStep[] memory onlyBtc = new BietixRouter.SwapStep[](1);
        onlyBtc[0] = all[0];
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        router.sell(shares, address(usdc), 0, onlyBtc, block.timestamp, alice);
        vm.stopPrank();
        uint256 used = router.sellUsedUsd();
        assertApproxEqRel(used, 500e18, 0.02e18);
        assertGt(weth.balanceOf(alice), 0, "el ETH no vendido vuelve al usuario");
    }

    /// Ventana móvil: no se puede vender el doble del límite justo en el cambio de ventana.
    function test_sell_rollingWindowBlocksDoubleSpendAtBoundary() public {
        vm.prank(guardian);
        router.decreaseSellLimit(1_500e18);
        uint256 s1 = _buy(alice, address(usdc), 1_400e6);
        uint256 s2 = _buy(bob, address(usdc), 1_400e6);
        _sellAll(alice, s1); // ~$1.390 usados

        // 1 hora después solo se recuperó 1/24 del cupo (~$62): la segunda venta no entra
        vm.warp(block.timestamp + 1 hours);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), s2, 0);
        vm.startPrank(bob);
        vault.approve(address(router), s2);
        vm.expectPartialRevert(BietixRouter.SellLimitExceeded.selector);
        router.sell(s2, address(usdc), 0, steps, block.timestamp, bob);
        vm.stopPrank();
        uint256 cap = router.sellCapacityUsd();
        assertApproxEqAbs(cap, 1_500e18 - router.sellUsedUsd() + 1_500e18 / 24, 20e18);

        // a las 12 h se recuperó la mitad
        vm.warp(block.timestamp + 11 hours);
        assertGt(router.sellCapacityUsd(), 750e18);
        assertLt(router.sellCapacityUsd(), 900e18);
    }

    /// L-1: las listas de stables y de agregadores no se pueden cruzar con activos ni contratos propios.
    function test_lists_crossChecked() public {
        vm.startPrank(timelock);
        address[5] memory badStables =
            [address(dex), address(wbtc), address(weth), address(vault), address(router)];
        for (uint256 i; i < badStables.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(BietixRouter.StableNotAllowed.selector, badStables[i]));
            router.addStable(badStables[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.TargetNotAllowed.selector, address(router)));
        router.addSwapTarget(address(router));
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.TargetNotAllowed.selector, address(guard)));
        router.addSwapTarget(address(guard));
        vm.stopPrank();
    }

    // ═══════════════════════════════ Fuzz ═══════════════════════════════

    /// Para cualquier monto y slippage aceptable, el Router queda limpio y el usuario recibe un valor justo.
    function testFuzz_buy_cleanAndFair(uint256 amountUsd, uint256 lossBps) public {
        amountUsd = bound(amountUsd, 20, 25_000);
        lossBps = bound(lossBps, 0, 90);
        uint256 amountIn = amountUsd * 1e6;
        _fund(alice, address(usdc), amountIn);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), amountIn, lossBps);
        vm.prank(alice);
        uint256 shares = router.buy(address(usdc), amountIn, 0, steps, block.timestamp, alice);
        _assertRouterClean();

        // valor de los BIETIX + polvo devuelto ≥ entrada − comisiones − slippage − 1 USD de redondeos
        uint256 worth = guard.indexPriceUsd(UNIT_BTC, UNIT_ETH) * shares / 1e18
            + guard.basketValueUsd(wbtc.balanceOf(alice), weth.balanceOf(alice));
        uint256 floor = amountUsd * 1e18 * (10_000 - BUY_FEE_BPS - VAULT_FEE_BPS - lossBps) / 10_000;
        assertGe(worth + 1e18, floor);
    }

    /// Comprar y vender enseguida nunca devuelve más de lo que se puso.
    function testFuzz_roundTrip_noProfit(uint256 amountUsd) public {
        amountUsd = bound(amountUsd, 20, 25_000);
        uint256 amountIn = amountUsd * 1e6;
        uint256 shares = _buy(alice, address(usdc), amountIn);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        uint256 out = router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);
        vm.stopPrank();
        assertLt(out, amountIn);
        _assertRouterClean();
    }

    // ═══════════════════════════════ Ayudas ═══════════════════════════════

    function _sellAll(address user, uint256 shares) internal returns (uint256 out) {
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 0);
        vm.startPrank(user);
        vault.approve(address(router), shares);
        out = router.sell(shares, address(usdc), 0, steps, block.timestamp, user);
        vm.stopPrank();
    }

    function _copy(BietixRouter.SwapStep[] memory a)
        internal
        pure
        returns (BietixRouter.SwapStep[] memory b)
    {
        b = new BietixRouter.SwapStep[](a.length);
        for (uint256 i; i < a.length; i++) {
            b[i] = BietixRouter.SwapStep(a[i].target, a[i].tokenIn, a[i].amountIn, a[i].data);
        }
    }
}
