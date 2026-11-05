// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BietixVault} from "../../src/BietixVault.sol";
import {BietixRouter} from "../../src/BietixRouter.sol";
import {GuardianCanceller} from "../../src/GuardianCanceller.sol";
import {SystemTestBase} from "../utils/SystemTestBase.sol";
import {noAddresses} from "../utils/Empty.sol";

/// @notice Ramas defensivas que solo se alcanzan con configuraciones inválidas, tokens maliciosos o usos
///         indebidos. Completan la cobertura del 100% y documentan que cada control realmente actúa.
contract CoverageTest is SystemTestBase {
    // ─────────────────────────────── Constructores ───────────────────────────────

    function _routerConfig(uint256 buyFee, uint256 sellFee)
        internal
        view
        returns (BietixRouter.Config memory)
    {
        return BietixRouter.Config({
            vault: vault,
            oracle: guard,
            admin: timelock,
            adminTransferDelay: 2 days,
            safe: safe,
            guardian: guardian,
            treasury: treasury,
            buyFeeBps: buyFee,
            sellFeeBps: sellFee,
            maxTradeUsd: MAX_TRADE,
            sellLimitUsd: SELL_LIMIT,
            stables: noAddresses(),
            swapTargets: noAddresses()
        });
    }

    function test_router_constructorRejectsFeesAboveCap() public {
        uint256 cap = router.MAX_FEE_BPS();
        vm.expectRevert(BietixRouter.FeeTooHigh.selector);
        new BietixRouter(_routerConfig(cap + 1, 0));
        vm.expectRevert(BietixRouter.FeeTooHigh.selector);
        new BietixRouter(_routerConfig(0, cap + 1));
        new BietixRouter(_routerConfig(cap, cap)); // justo en el tope sí
    }

    function test_vault_constructorRejectsFeeAboveCap() public {
        BietixVault.Config memory c = BietixVault.Config({
            assetBtc: IERC20(address(wbtc)),
            assetEth: IERC20(address(weth)),
            unitBtc: 10_000,
            unitEth: 3e15,
            admin: timelock,
            adminTransferDelay: 2 days,
            safe: safe,
            guardian: guardian,
            treasury: treasury,
            mintFeeBps: 101,
            supplyCap: 1e24
        });
        vm.expectRevert(BietixVault.FeeTooHigh.selector);
        new BietixVault("Bietix", "BIETIX", c);
    }

    function test_canceller_constructorRejectsZeroAddresses() public {
        TimelockController t = TimelockController(payable(makeAddr("tl")));
        vm.expectRevert(GuardianCanceller.ZeroAddress.selector);
        new GuardianCanceller(TimelockController(payable(address(0))), safe, guardian, 1 days);
        vm.expectRevert(GuardianCanceller.ZeroAddress.selector);
        new GuardianCanceller(t, address(0), guardian, 1 days);
        vm.expectRevert(GuardianCanceller.ZeroAddress.selector);
        new GuardianCanceller(t, safe, address(0), 1 days);
    }

    function test_canceller_cancelChangeWithoutPendingReverts() public {
        GuardianCanceller c =
            new GuardianCanceller(TimelockController(payable(makeAddr("tl"))), safe, guardian, 1 days);
        vm.prank(safe);
        vm.expectRevert(GuardianCanceller.NoPendingChange.selector);
        c.cancelGuardianChange();
    }

    // ─────────────── Agregador o token que saca más de lo autorizado ───────────────

    /// Un token con rebase negativo (o un agregador que logra quitar saldo) en la compra: se detecta.
    function test_buy_detectsOutflowAboveDeclared() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 10);
        usdc.mint(address(router), 5); // el Router tiene saldo previo que podría perder
        dex.setSlashToken(address(usdc));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.BalanceMismatch.selector, address(usdc)));
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, alice);
    }

    /// Lo mismo en la venta, para el segundo activo (WETH).
    function test_sell_detectsOutflowAboveDeclaredOnSecondAsset() public {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _sellSteps(address(usdc), shares, 10);
        weth.mint(address(router), 5);
        dex.setSlashToken(address(weth));
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.BalanceMismatch.selector, address(weth)));
        router.sell(shares, address(usdc), 0, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    // ─────────────── Regla de no retención (invariante I4) ───────────────
    // Si el receptor es el propio Router, los fondos quedarían atrapados en él: la regla lo rechaza.

    function test_buy_receiverRouterIsRejected() public {
        _fund(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory steps = _buySteps(address(usdc), 1_000e6, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.BalanceMismatch.selector, address(vault)));
        router.buy(address(usdc), 1_000e6, 0, steps, block.timestamp, address(router));
    }

    function _sellTo(address receiver, bool sellBtc, bool sellEth, address expectedToken) internal {
        uint256 shares = _buy(alice, address(usdc), 1_000e6);
        BietixRouter.SwapStep[] memory all = _sellSteps(address(usdc), shares, 10);
        uint256 n = (sellBtc ? 1 : 0) + (sellEth ? 1 : 0);
        BietixRouter.SwapStep[] memory steps = new BietixRouter.SwapStep[](n);
        uint256 k;
        if (sellBtc) steps[k++] = all[0];
        if (sellEth) steps[k] = all[1];
        vm.startPrank(alice);
        vault.approve(address(router), shares);
        vm.expectRevert(abi.encodeWithSelector(BietixRouter.BalanceMismatch.selector, expectedToken));
        router.sell(shares, address(usdc), 0, steps, block.timestamp, receiver);
        vm.stopPrank();
    }

    function test_sell_receiverRouterIsRejected_unsoldBtc() public {
        _sellTo(address(router), false, true, address(wbtc));
    }

    function test_sell_receiverRouterIsRejected_unsoldEth() public {
        _sellTo(address(router), true, false, address(weth));
    }

    function test_sell_receiverRouterIsRejected_stable() public {
        _sellTo(address(router), true, true, address(usdc));
    }

    // ─────────────── Reserva de redondeo de `sharesFor` ───────────────

    /// Lo que pide el vault para acuñar `sharesFor(b, e)` nunca supera b y e, con cualquier comisión permitida.
    function testFuzz_sharesFor_neverExceedsAmounts(uint256 btcAmount, uint256 ethAmount, uint256 feeBps)
        public
    {
        btcAmount = bound(btcAmount, 0, 1e12); // hasta 10.000 BTC
        ethAmount = bound(ethAmount, 0, 1e24); // hasta 1.000.000 ETH
        feeBps = bound(feeBps, 0, vault.MAX_MINT_FEE_BPS());
        vm.prank(timelock);
        vault.setMintFee(feeBps);

        uint256 shares = router.sharesFor(btcAmount, ethAmount);
        if (shares == 0) return;
        (uint256 b, uint256 e, uint256 fb, uint256 fe) = vault.previewMint(shares);
        assertLe(b + fb, btcAmount, "pide mas BTC del disponible");
        assertLe(e + fe, ethAmount, "pide mas ETH del disponible");
    }
}
