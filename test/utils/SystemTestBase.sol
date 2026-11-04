// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BietixVault} from "../../src/BietixVault.sol";
import {OracleGuard} from "../../src/OracleGuard.sol";
import {noFeeds, noStables, noAddresses} from "../utils/Empty.sol";
import {BietixRouter} from "../../src/BietixRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockSwapTarget, MockUSDT} from "../mocks/MockSwapTarget.sol";

/// @notice Despliega el sistema completo (Vault + OracleGuard + Router) con tokens y feeds falsos.
abstract contract SystemTestBase is Test {
    uint256 internal constant UNIT_BTC = 10_000;
    uint256 internal constant UNIT_ETH = 3e15;
    uint256 internal constant VAULT_FEE_BPS = 5; // 0,05% In-Kind
    uint256 internal constant BUY_FEE_BPS = 25; // 0,25% Router → total compra 0,30%
    uint256 internal constant SELL_FEE_BPS = 30; // 0,30%
    uint256 internal constant MAX_TRADE = 25_000e18;
    uint256 internal constant SELL_LIMIT = 50_000e18;

    address internal timelock = makeAddr("timelock");
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    MockERC20 internal wbtc;
    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockUSDT internal usdt;

    MockAggregator internal seqFeed;
    MockAggregator internal btcFeed;
    MockAggregator internal ethFeed;
    MockAggregator internal wrapFeed;
    MockAggregator internal usdcFeed;
    MockAggregator internal usdtFeed;

    BietixVault internal vault;
    OracleGuard internal guard;
    BietixRouter internal router;
    MockSwapTarget internal dex;

    function setUp() public virtual {
        vm.warp(30 days);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockUSDT();

        // Oráculos
        seqFeed = new MockAggregator(0, 0);
        seqFeed.setStartedAt(block.timestamp - 2 hours);
        btcFeed = new MockAggregator(8, 80_000e8);
        ethFeed = new MockAggregator(8, 2_667e8);
        wrapFeed = new MockAggregator(8, 1e8);
        usdcFeed = new MockAggregator(8, 1e8);
        usdtFeed = new MockAggregator(8, 1e8);

        guard = new OracleGuard(
            timelock,
            2 days,
            safe,
            guardian,
            8,
            18,
            AggregatorV3Interface(address(seqFeed)),
            noFeeds(),
            noStables()
        );

        // Vault
        vault = new BietixVault(
            "Bietix",
            "BIETIX",
            BietixVault.Config({
                assetBtc: IERC20(address(wbtc)),
                assetEth: IERC20(address(weth)),
                unitBtc: UNIT_BTC,
                unitEth: UNIT_ETH,
                admin: timelock,
                adminTransferDelay: 2 days,
                safe: safe,
                guardian: guardian,
                treasury: treasury,
                mintFeeBps: VAULT_FEE_BPS,
                supplyCap: 1_000_000e18
            })
        );

        // Router
        router = new BietixRouter(
            BietixRouter.Config({
                vault: vault,
                oracle: guard,
                admin: timelock,
                adminTransferDelay: 2 days,
                safe: safe,
                guardian: guardian,
                treasury: treasury,
                buyFeeBps: BUY_FEE_BPS,
                sellFeeBps: SELL_FEE_BPS,
                maxTradeUsd: MAX_TRADE,
                sellLimitUsd: SELL_LIMIT,
                stables: noAddresses(),
                swapTargets: noAddresses()
            })
        );
        dex = new MockSwapTarget();

        vm.startPrank(timelock);
        guard.setFeed(guard.BTC_USD(), btcFeed, 3900, 1_000e18, 10_000_000e18);
        guard.setFeed(guard.ETH_USD(), ethFeed, 3900, 50e18, 1_000_000e18);
        guard.setFeed(guard.WBTC_BTC(), wrapFeed, 90_000, 0.5e18, 1.5e18);
        guard.setStable(address(usdc), 6, usdcFeed, 90_000, 0.5e18, 1.5e18);
        guard.setStable(address(usdt), 6, usdtFeed, 90_000, 0.5e18, 1.5e18);
        router.addStable(address(usdc));
        router.addStable(address(usdt));
        router.addSwapTarget(address(dex));
        vm.stopPrank();
    }

    // ───────────────────────────── Ayudas de compra ─────────────────────────────

    /// @dev Arma los dos swaps de una compra: mitad del neto a WBTC y mitad a WETH, con `lossBps` de slippage.
    function _buySteps(address stable, uint256 amountIn, uint256 lossBps)
        internal
        view
        returns (BietixRouter.SwapStep[] memory steps)
    {
        uint256 net = amountIn - (amountIn * router.buyFeeBps() + 9_999) / 10_000;
        uint256 half = net / 2;
        uint256 rest = net - half;
        // valor en USD (18 dec) de cada mitad, con la pérdida aplicada
        uint256 usdB = half * 1e12 * (10_000 - lossBps) / 10_000;
        uint256 usdE = rest * 1e12 * (10_000 - lossBps) / 10_000;
        uint256 btcOut = usdB * 1e8 / guard.wbtcUsd();
        uint256 ethOut = usdE * 1e18 / guard.ethUsd();

        steps = new BietixRouter.SwapStep[](2);
        steps[0] = _step(stable, half, address(wbtc), btcOut);
        steps[1] = _step(stable, rest, address(weth), ethOut);
    }

    /// @dev Arma los swaps de una venta: todo el WBTC y WETH redimido a la stable, con `lossBps` de slippage.
    function _sellSteps(address stable, uint256 shares, uint256 lossBps)
        internal
        view
        returns (BietixRouter.SwapStep[] memory steps)
    {
        (uint256 b, uint256 e) = vault.previewRedeem(shares);
        uint256 usdB = b * guard.wbtcUsd() / 1e8 * (10_000 - lossBps) / 10_000;
        uint256 usdE = e * guard.ethUsd() / 1e18 * (10_000 - lossBps) / 10_000;
        steps = new BietixRouter.SwapStep[](2);
        steps[0] = _step(address(wbtc), b, stable, usdB / 1e12);
        steps[1] = _step(address(weth), e, stable, usdE / 1e12);
    }

    function _step(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (BietixRouter.SwapStep memory)
    {
        return BietixRouter.SwapStep({
            target: address(dex),
            tokenIn: tokenIn,
            amountIn: amountIn,
            data: abi.encodeCall(
                MockSwapTarget.swap, (tokenIn, amountIn, tokenOut, amountOut, address(router))
            )
        });
    }

    function _fund(address user, address stable, uint256 amount) internal {
        MockERC20(stable).mint(user, amount);
        vm.prank(user);
        IERC20(stable).approve(address(router), amount);
    }

    function _buy(address user, address stable, uint256 amountIn) internal returns (uint256 shares) {
        _fund(user, stable, amountIn);
        BietixRouter.SwapStep[] memory steps = _buySteps(stable, amountIn, 10);
        vm.prank(user);
        shares = router.buy(stable, amountIn, 0, steps, block.timestamp, user);
    }

    function _assertRouterClean() internal view {
        assertEq(wbtc.balanceOf(address(router)), 0, "router con WBTC");
        assertEq(weth.balanceOf(address(router)), 0, "router con WETH");
        assertEq(usdc.balanceOf(address(router)), 0, "router con USDC");
        assertEq(usdt.balanceOf(address(router)), 0, "router con USDT");
        assertEq(vault.balanceOf(address(router)), 0, "router con BIETIX");
        assertEq(usdc.allowance(address(router), address(dex)), 0, "aprobacion USDC abierta");
        assertEq(usdt.allowance(address(router), address(dex)), 0, "aprobacion USDT abierta");
        assertEq(wbtc.allowance(address(router), address(dex)), 0, "aprobacion WBTC abierta");
        assertEq(weth.allowance(address(router), address(dex)), 0, "aprobacion WETH abierta");
        assertEq(wbtc.allowance(address(router), address(vault)), 0, "aprobacion vault abierta");
        assertEq(weth.allowance(address(router), address(vault)), 0, "aprobacion vault abierta");
    }
}
