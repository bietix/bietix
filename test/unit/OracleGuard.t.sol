// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OracleGuard} from "../../src/OracleGuard.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

/// @notice Pruebas del OracleGuard (secciones 4.3 a 4.9 de las especificaciones).
contract OracleGuardTest is Test {
    OracleGuard internal guard;
    MockAggregator internal seq;
    MockAggregator internal btcUsd;
    MockAggregator internal ethUsd;
    MockAggregator internal wbtcBtc;
    MockAggregator internal usdcUsd;
    MockAggregator internal usdtUsd;

    address internal timelock = makeAddr("timelock");
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");
    address internal usdc = makeAddr("USDC");
    address internal usdt = makeAddr("USDT");

    bytes32 internal BTC;
    bytes32 internal ETH;
    bytes32 internal WRAP;

    uint32 internal constant HOUR_STALE = 3900; // heartbeat 1 h + tolerancia
    uint32 internal constant DAY_STALE = 90_000; // heartbeat 24 h + tolerancia

    function setUp() public {
        vm.warp(30 days);
        seq = new MockAggregator(0, 0);
        seq.setStartedAt(block.timestamp - 2 hours); // sequencer activo hace 2 h

        btcUsd = new MockAggregator(8, 80_000e8);
        ethUsd = new MockAggregator(8, 2_667e8);
        wbtcBtc = new MockAggregator(8, 1e8);
        usdcUsd = new MockAggregator(8, 1e8);
        usdtUsd = new MockAggregator(8, 1e8);

        guard = new OracleGuard(timelock, 2 days, safe, guardian, 8, 18, AggregatorV3Interface(address(seq)));
        BTC = guard.BTC_USD();
        ETH = guard.ETH_USD();
        WRAP = guard.WBTC_BTC();

        vm.startPrank(timelock);
        guard.setFeed(BTC, btcUsd, HOUR_STALE, 1_000e18, 10_000_000e18);
        guard.setFeed(ETH, ethUsd, HOUR_STALE, 50e18, 1_000_000e18);
        guard.setFeed(WRAP, wbtcBtc, DAY_STALE, 0.5e18, 1.5e18);
        guard.setStable(usdc, 6, usdcUsd, DAY_STALE, 0.5e18, 1.5e18);
        guard.setStable(usdt, 6, usdtUsd, DAY_STALE, 0.5e18, 1.5e18);
        vm.stopPrank();
    }

    // ─────────────────────────── Lectura de precios ───────────────────────────

    function test_price_normalizesTo18Decimals() public view {
        assertEq(guard.price(BTC), 80_000e18);
        assertEq(guard.price(ETH), 2_667e18);
        assertEq(guard.wrapperRatio(), 1e18);
        assertEq(guard.stableUsd(usdc), 1e18);
    }

    function test_price_handlesOtherDecimals() public {
        MockAggregator f18 = new MockAggregator(18, 2_000e18);
        MockAggregator f20 = new MockAggregator(20, 2_000e20);
        vm.startPrank(timelock);
        guard.setFeed(ETH, f18, HOUR_STALE, 50e18, 1_000_000e18);
        assertEq(guard.price(ETH), 2_000e18);
        guard.setFeed(ETH, f20, HOUR_STALE, 50e18, 1_000_000e18);
        assertEq(guard.price(ETH), 2_000e18);
        vm.stopPrank();
    }

    function test_price_revertsOnZeroOrNegative() public {
        btcUsd.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.InvalidPrice.selector, BTC));
        guard.price(BTC);
        btcUsd.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.InvalidPrice.selector, BTC));
        guard.price(BTC);
    }

    function test_price_revertsOnBadTimestamp() public {
        btcUsd.set(80_000e8, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.InvalidPrice.selector, BTC));
        guard.price(BTC);
        btcUsd.set(80_000e8, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.InvalidPrice.selector, BTC));
        guard.price(BTC);
    }

    function test_price_revertsWhenStale() public {
        btcUsd.set(80_000e8, block.timestamp - HOUR_STALE); // justo en el límite: OK
        assertEq(guard.price(BTC), 80_000e18);
        btcUsd.set(80_000e8, block.timestamp - HOUR_STALE - 1);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.StalePrice.selector, BTC));
        guard.price(BTC);
    }

    function test_price_revertsOutOfSanityRange() public {
        btcUsd.setAnswer(999e8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.PriceOutOfRange.selector, BTC));
        guard.price(BTC);
        btcUsd.setAnswer(10_000_001e8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.PriceOutOfRange.selector, BTC));
        guard.price(BTC);
    }

    function test_price_revertsWhenFeedFails() public {
        btcUsd.setRevert(true);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedCallFailed.selector, BTC));
        guard.price(BTC);
    }

    function test_price_revertsWhenNotSet() public {
        bytes32 k = keccak256("NADA");
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedNotSet.selector, k));
        guard.price(k);
    }

    function test_stable_unsupportedReverts() public {
        address dai = makeAddr("DAI");
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.StableNotSupported.selector, dai));
        guard.stableUsd(dai);
    }

    // ─────────────────────────────── Sequencer ───────────────────────────────

    function test_sequencer_ok() public view {
        guard.checkSequencer();
    }

    function test_sequencer_downReverts() public {
        seq.setAnswer(1);
        vm.expectRevert(OracleGuard.SequencerDown.selector);
        guard.checkSequencer();
    }

    function test_sequencer_notInitializedReverts() public {
        seq.setStartedAt(0);
        vm.expectRevert(OracleGuard.SequencerNotInitialized.selector);
        guard.checkSequencer();
    }

    function test_sequencer_gracePeriod() public {
        seq.setStartedAt(block.timestamp - 1 hours); // justo 1 h: todavía en gracia
        vm.expectRevert(OracleGuard.GracePeriodNotOver.selector);
        guard.checkSequencer();
        seq.setStartedAt(block.timestamp - 1 hours - 1);
        guard.checkSequencer();
    }

    // ─────────────────────────── Valuación ───────────────────────────

    function test_wbtcUsd_usesWrapperRatio() public {
        assertEq(guard.wbtcUsd(), 80_000e18);
        wbtcBtc.setAnswer(0.97e8);
        assertEq(guard.wbtcUsd(), 77_600e18);
    }

    function test_indexPrice() public view {
        // 1 DUOX = 0,0001 BTC ($8) + 0,003 ETH ($8,001)
        assertEq(guard.indexPriceUsd(10_000, 3e15), 16.001e18);
    }

    function test_wrapperAlert() public {
        assertFalse(guard.wrapperAlert());
        wbtcBtc.setAnswer(0.985e8);
        assertTrue(guard.wrapperAlert());
    }

    // ─────────────────────────── Control de compra ───────────────────────────

    function test_checkBuy_okWithinMargin() public view {
        // 1.000 USDC → canasta que vale $995 (0,5% peor): dentro del margen de 1%
        (uint256 b, uint256 e) = _basketWorth(995e18);
        guard.checkBuy(usdc, 1_000e6, b, e);
    }

    function test_checkBuy_revertsWorseThanMargin() public {
        (uint256 b, uint256 e) = _basketWorth(985e18); // 1,5% peor
        vm.expectRevert();
        guard.checkBuy(usdc, 1_000e6, b, e);
    }

    function test_checkBuy_blockedWhenWrapperDepegged() public {
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        wbtcBtc.setAnswer(0.979e8);
        vm.expectRevert(OracleGuard.WrapperDepegged.selector);
        guard.checkBuy(usdc, 1_000e6, b, e);
    }

    function test_checkBuy_allowedInAlertZone() public {
        wbtcBtc.setAnswer(0.985e8);
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        guard.checkBuy(usdc, 1_000e6, b, e);
    }

    function test_checkBuy_revertsOnStableDepeg() public {
        usdtUsd.setAnswer(0.97e8);
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.StablePriceTooLow.selector, usdt));
        guard.checkBuy(usdt, 1_000e6, b, e);
        // USDC sigue funcionando
        guard.checkBuy(usdc, 1_000e6, b, e);
    }

    function test_checkBuy_usesRealStablePrice() public {
        // USDT a $0,985: 1.000 USDT valen $985, así que una canasta de $980 está dentro del margen
        usdtUsd.setAnswer(0.985e8);
        (uint256 b, uint256 e) = _basketWorth(980e18);
        guard.checkBuy(usdt, 1_000e6, b, e);
    }

    function test_checkBuy_revertsWhenSequencerDown() public {
        seq.setAnswer(1);
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        vm.expectRevert(OracleGuard.SequencerDown.selector);
        guard.checkBuy(usdc, 1_000e6, b, e);
    }

    function test_checkBuy_revertsWhenFeedStale() public {
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        vm.warp(block.timestamp + HOUR_STALE + 1);
        seq.setStartedAt(block.timestamp - 2 hours);
        vm.expectRevert();
        guard.checkBuy(usdc, 1_000e6, b, e);
    }

    // ─────────────────────────── Control de venta ───────────────────────────

    function test_checkSell_ok() public view {
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        guard.checkSell(usdc, b, e, 995e6);
    }

    function test_checkSell_revertsWorseThanMargin() public {
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        vm.expectRevert();
        guard.checkSell(usdc, b, e, 985e6);
    }

    function test_checkSell_allowedWhenWrapperDepegged() public {
        (uint256 b, uint256 e) = _basketWorth(1_000e18);
        wbtcBtc.setAnswer(0.9e8); // con el wrapper a 0,90 la canasta vale menos y la venta igual se permite
        uint256 worth = guard.basketValueUsd(b, e);
        guard.checkSell(usdc, b, e, worth / 1e12);
    }

    // ─────────────────────────── Permisos y límites ───────────────────────────

    function test_margin_tightenAndRelax() public {
        vm.prank(guardian);
        guard.tightenMargin(50);
        assertEq(guard.marginBps(), 50);
        vm.prank(guardian);
        vm.expectRevert(OracleGuard.NotTighter.selector);
        guard.tightenMargin(80);
        vm.prank(guardian);
        vm.expectRevert();
        guard.relaxMargin(80);
        vm.prank(safe);
        vm.expectRevert();
        guard.relaxMargin(80);

        vm.prank(timelock);
        guard.relaxMargin(300);
        assertEq(guard.marginBps(), 300);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.relaxMargin(301);
    }

    function test_staleness_tightenAndRelax() public {
        vm.prank(guardian);
        guard.tightenStaleness(BTC, 3600);
        assertEq(guard.feedConfig(BTC).maxStaleness, 3600);
        vm.prank(guardian);
        vm.expectRevert(OracleGuard.NotTighter.selector);
        guard.tightenStaleness(BTC, 0);
        vm.prank(guardian);
        vm.expectRevert();
        guard.relaxStaleness(BTC, 7200);
        vm.prank(timelock);
        guard.relaxStaleness(BTC, 26 hours);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.relaxStaleness(BTC, 26 hours + 1);
    }

    function test_grace_tightenAndRelax() public {
        vm.prank(guardian);
        guard.tightenGracePeriod(2 hours);
        assertEq(guard.gracePeriod(), 2 hours);
        vm.prank(guardian);
        vm.expectRevert();
        guard.relaxGracePeriod(1 hours);
        vm.prank(timelock);
        guard.relaxGracePeriod(30 minutes);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.NotLooser.selector);
        guard.relaxGracePeriod(40 minutes);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.relaxGracePeriod(29 minutes);
    }

    function test_wrapperThreshold_tightenAndRelax() public {
        vm.prank(guardian);
        guard.tightenWrapperThreshold(0.99e18);
        vm.prank(guardian);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.tightenWrapperThreshold(1.01e18);
        vm.prank(timelock);
        guard.relaxWrapperThreshold(0.95e18);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.NotLooser.selector);
        guard.relaxWrapperThreshold(0.96e18);
        vm.prank(guardian);
        guard.tightenWrapperThreshold(0.96e18);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.relaxWrapperThreshold(0.94e18);
    }

    function test_minStablePrice_tightenAndRelax() public {
        vm.prank(guardian);
        guard.tightenMinStablePrice(0.99e18);
        vm.prank(attacker);
        vm.expectRevert();
        guard.tightenMinStablePrice(0.995e18);
        vm.prank(timelock);
        guard.relaxMinStablePrice(0.95e18);
        vm.prank(guardian);
        guard.tightenMinStablePrice(0.96e18);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.relaxMinStablePrice(0.94e18);
    }

    function test_wrapperAlertThreshold_onlyAdminAndBounded() public {
        vm.prank(guardian);
        vm.expectRevert();
        guard.setWrapperAlertThreshold(0.995e18);
        vm.prank(timelock);
        guard.setWrapperAlertThreshold(0.995e18);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.setWrapperAlertThreshold(0.9e18);
    }

    function test_setFeed_onlyAdminAndValidated() public {
        MockAggregator f = new MockAggregator(8, 80_000e8);
        address[3] memory notAllowed = [guardian, safe, attacker];
        for (uint256 i; i < notAllowed.length; i++) {
            vm.prank(notAllowed[i]);
            vm.expectRevert();
            guard.setFeed(BTC, f, HOUR_STALE, 1, 2);
        }
        vm.startPrank(timelock);
        vm.expectRevert(OracleGuard.ZeroAddress.selector);
        guard.setFeed(BTC, AggregatorV3Interface(address(0)), HOUR_STALE, 1, 2);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.setFeed(BTC, f, 0, 1, 2);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.setFeed(BTC, f, 26 hours + 1, 1, 2);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.setFeed(BTC, f, HOUR_STALE, 2, 2);

        MockAggregator bad = new MockAggregator(0, 1);
        vm.expectRevert(OracleGuard.InvalidFeed.selector);
        guard.setFeed(BTC, bad, HOUR_STALE, 1, 2);

        MockAggregator zeroPrice = new MockAggregator(8, 0);
        vm.expectRevert(OracleGuard.InvalidFeed.selector);
        guard.setFeed(BTC, zeroPrice, HOUR_STALE, 1, 2);

        MockAggregator broken = new MockAggregator(8, 1);
        broken.setRevert(true);
        vm.expectRevert();
        guard.setFeed(BTC, broken, HOUR_STALE, 1, 2);
        vm.stopPrank();
    }

    function test_setStable_validated() public {
        MockAggregator f = new MockAggregator(8, 1e8);
        vm.startPrank(timelock);
        vm.expectRevert(OracleGuard.ZeroAddress.selector);
        guard.setStable(address(0), 6, f, DAY_STALE, 0.5e18, 1.5e18);
        vm.expectRevert(OracleGuard.InvalidFeed.selector);
        guard.setStable(makeAddr("X"), 0, f, DAY_STALE, 0.5e18, 1.5e18);
        vm.stopPrank();
    }

    function test_setSequencerFeed_onlyAdmin() public {
        MockAggregator s2 = new MockAggregator(0, 0);
        vm.prank(safe);
        vm.expectRevert();
        guard.setSequencerFeed(s2);
        vm.prank(timelock);
        vm.expectRevert(OracleGuard.ZeroAddress.selector);
        guard.setSequencerFeed(AggregatorV3Interface(address(0)));
        vm.prank(timelock);
        guard.setSequencerFeed(s2);
        assertEq(address(guard.sequencerFeed()), address(s2));
    }

    function test_revokeGuardian_bySafe() public {
        vm.prank(attacker);
        vm.expectRevert();
        guard.revokeGuardian(guardian);
        vm.prank(safe);
        guard.revokeGuardian(guardian);
        vm.prank(guardian);
        vm.expectRevert();
        guard.tightenMargin(10);
    }

    function test_constructor_zeroAddresses() public {
        vm.expectRevert(OracleGuard.ZeroAddress.selector);
        new OracleGuard(timelock, 2 days, address(0), guardian, 8, 18, AggregatorV3Interface(address(seq)));
        vm.expectRevert(OracleGuard.ZeroAddress.selector);
        new OracleGuard(timelock, 2 days, safe, address(0), 8, 18, AggregatorV3Interface(address(seq)));
        vm.expectRevert(OracleGuard.ZeroAddress.selector);
        new OracleGuard(timelock, 2 days, safe, guardian, 8, 18, AggregatorV3Interface(address(0)));
    }

    function test_params_rejectWrongDirectionAndBounds() public {
        bytes32 none = keccak256("NADA");
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedNotSet.selector, none));
        guard.tightenStaleness(none, 10);
        vm.expectRevert(OracleGuard.NotTighter.selector);
        guard.tightenStaleness(BTC, HOUR_STALE);
        vm.expectRevert(OracleGuard.NotTighter.selector);
        guard.tightenGracePeriod(1 hours);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.tightenGracePeriod(1 days + 1);
        vm.expectRevert(OracleGuard.NotTighter.selector);
        guard.tightenWrapperThreshold(0.98e18);
        vm.expectRevert(OracleGuard.NotTighter.selector);
        guard.tightenMinStablePrice(0.98e18);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.tightenMinStablePrice(1.01e18);
        vm.stopPrank();

        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedNotSet.selector, none));
        guard.relaxStaleness(none, 10);
        vm.expectRevert(OracleGuard.NotLooser.selector);
        guard.relaxStaleness(BTC, HOUR_STALE);
        vm.expectRevert(OracleGuard.NotLooser.selector);
        guard.relaxMargin(100);
        vm.expectRevert(OracleGuard.NotLooser.selector);
        guard.relaxMinStablePrice(0.98e18);
        vm.expectRevert(OracleGuard.OutOfBounds.selector);
        guard.setWrapperAlertThreshold(1.01e18);
        vm.stopPrank();
    }

    // ─────────────────────────────── Fuzz ───────────────────────────────

    /// El control acepta exactamente las ejecuciones con pérdida ≤ margen.
    function testFuzz_checkBuy_marginBoundary(uint256 amountUsd, uint256 lossBps) public {
        amountUsd = bound(amountUsd, 10, 25_000);
        lossBps = bound(lossBps, 0, 500);
        uint256 valueIn = amountUsd * 1e18;
        (uint256 b, uint256 e) = _basketWorth(valueIn * (10_000 - lossBps) / 10_000);
        uint256 worth = guard.basketValueUsd(b, e);
        bool shouldPass = worth * 10_000 >= valueIn * (10_000 - guard.marginBps());
        if (shouldPass) {
            guard.checkBuy(usdc, amountUsd * 1e6, b, e);
        } else {
            vm.expectRevert();
            guard.checkBuy(usdc, amountUsd * 1e6, b, e);
        }
        if (lossBps <= 99) assertTrue(shouldPass);
        if (lossBps >= 101) assertFalse(shouldPass);
    }

    /// La valuación nunca supone WBTC = BTC: con el wrapper devaluado, la canasta vale menos.
    function testFuzz_wrapperRatioLowersValue(uint256 ratio) public {
        ratio = bound(ratio, 0.5e8, 1e8);
        uint256 before = guard.basketValueUsd(1e8, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        wbtcBtc.setAnswer(int256(ratio));
        uint256 afterV = guard.basketValueUsd(1e8, 0);
        assertEq(afterV, before * ratio / 1e8);
    }

    // ─────────────────────────────── Ayudas ───────────────────────────────

    /// @dev Devuelve cantidades de WBTC y WETH (mitad y mitad) que valen `usd` al precio del oráculo.
    function _basketWorth(uint256 usd) internal view returns (uint256 btc, uint256 eth) {
        uint256 half = usd / 2;
        btc = half * 1e8 / guard.wbtcUsd();
        eth = (usd - half) * 1e18 / guard.ethUsd();
    }
}
