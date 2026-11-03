// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DuoxVault} from "../../src/DuoxVault.sol";
import {OracleGuard} from "../../src/OracleGuard.sol";
import {DuoxRouter} from "../../src/DuoxRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Interfaz mínima de SwapRouter02 de Uniswap V3.
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title Pruebas sobre un fork de Arbitrum One (sección 6.7 de las especificaciones)
/// @notice Usa los tokens, oráculos de Chainlink y pools de Uniswap V3 REALES.
///         Se saltean solas si no hay RPC configurado (variable ARBITRUM_RPC_URL en el archivo .env).
///         Correr con:  forge test --match-path "test/fork/*" -vv
contract ArbitrumForkTest is Test {
    // ─────────────── Direcciones en Arbitrum One ───────────────
    address internal constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC nativo
    address internal constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    address internal constant FEED_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant FEED_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant FEED_WBTC_BTC = 0x0017abAc5b6f291F9164e35B1234CA1D697f9CF4;
    address internal constant FEED_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address internal constant FEED_USDT_USD = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address internal constant FEED_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    address internal constant UNISWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // SwapRouter02

    uint24 internal constant FEE_005 = 500; // 0,05%
    uint24 internal constant FEE_001 = 100; // 0,01%

    address internal timelock = makeAddr("timelock");
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    DuoxVault internal vault;
    OracleGuard internal guard;
    DuoxRouter internal router;
    uint256 internal unitBtc;
    uint256 internal unitEth;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // sin RPC: las pruebas se saltean
        vm.createSelectFork(rpc);
        forked = true;

        // Oráculo con los feeds reales
        guard =
            new OracleGuard(timelock, 2 days, safe, guardian, 8, 18, AggregatorV3Interface(FEED_SEQUENCER));
        vm.startPrank(timelock);
        // En el fork se usa 26 h de antigüedad máxima para no depender de cuándo se actualizó cada feed;
        // los valores definitivos se fijan con los heartbeats publicados al desplegar (ver test_feeds_report).
        guard.setFeed(guard.BTC_USD(), AggregatorV3Interface(FEED_BTC_USD), 26 hours, 1_000e18, 10_000_000e18);
        guard.setFeed(guard.ETH_USD(), AggregatorV3Interface(FEED_ETH_USD), 26 hours, 50e18, 1_000_000e18);
        guard.setFeed(guard.WBTC_BTC(), AggregatorV3Interface(FEED_WBTC_BTC), 26 hours, 0.5e18, 1.5e18);
        guard.setStable(USDC, 6, AggregatorV3Interface(FEED_USDC_USD), 26 hours, 0.5e18, 1.5e18);
        guard.setStable(USDT, 6, AggregatorV3Interface(FEED_USDT_USD), 26 hours, 0.5e18, 1.5e18);
        vm.stopPrank();

        // Unidades por token calculadas como al lanzar: 0,0001 BTC + el ETH que vale lo mismo (50/50)
        unitBtc = 10_000;
        uint256 btcPart = guard.wbtcUsd() * unitBtc / 1e8; // USD (18 dec)
        unitEth = btcPart * 1e18 / guard.ethUsd();

        vault = new DuoxVault(
            "DUOX Index",
            "DUOX",
            DuoxVault.Config({
                assetBtc: IERC20(WBTC),
                assetEth: IERC20(WETH),
                unitBtc: unitBtc,
                unitEth: unitEth,
                admin: timelock,
                adminTransferDelay: 2 days,
                safe: safe,
                guardian: guardian,
                treasury: treasury,
                mintFeeBps: 5,
                supplyCap: type(uint256).max
            })
        );
        router = new DuoxRouter(
            DuoxRouter.Config({
                vault: vault,
                oracle: guard,
                admin: timelock,
                adminTransferDelay: 2 days,
                safe: safe,
                guardian: guardian,
                treasury: treasury,
                buyFeeBps: 25,
                sellFeeBps: 30,
                maxTradeUsd: 25_000e18,
                sellLimitUsd: 50_000e18
            })
        );
        vm.startPrank(timelock);
        router.addStable(USDC);
        router.addStable(USDT);
        router.addSwapTarget(UNISWAP_ROUTER);
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!forked) {
            console2.log("Sin ARBITRUM_RPC_URL: prueba de fork salteada");
            vm.skip(true);
        }
        _;
    }

    // ═══════════════════════════ Verificación de feeds ═══════════════════════════

    /// Confirma que cada dirección es el feed esperado y muestra su antigüedad (para fijar maxStaleness).
    function test_feeds_report() public onlyFork {
        _checkFeed(FEED_BTC_USD, "BTC / USD");
        _checkFeed(FEED_ETH_USD, "ETH / USD");
        _checkFeed(FEED_WBTC_BTC, "WBTC / BTC");
        _checkFeed(FEED_USDC_USD, "USDC / USD");
        _checkFeed(FEED_USDT_USD, "USDT / USD");
        guard.checkSequencer();
        console2.log("Sequencer de Arbitrum: activo");
        console2.log("Precio de 1 DUOX (USD x1e18):", guard.indexPriceUsd(unitBtc, unitEth));
        console2.log("unitBtc (sats):", unitBtc);
        console2.log("unitEth (wei):", unitEth);
    }

    // ═══════════════════════════ Compra y venta reales ═══════════════════════════

    function test_buySell_100() public onlyFork {
        _roundTrip(USDC, 100e6);
    }

    function test_buySell_1k() public onlyFork {
        _roundTrip(USDC, 1_000e6);
    }

    function test_buySell_10k() public onlyFork {
        _roundTrip(USDC, 10_000e6);
    }

    function test_buySell_25k() public onlyFork {
        _roundTrip(USDC, 25_000e6);
    }

    function test_buySell_USDT_1k() public onlyFork {
        _roundTrip(USDT, 1_000e6);
    }

    /// La salida In-Kind funciona con los tokens reales aunque el Router esté pausado.
    function test_inKindExit_realTokens() public onlyFork {
        uint256 shares = _buy(USDC, 1_000e6);
        vm.prank(guardian);
        router.pause();
        vm.prank(alice);
        (uint256 b, uint256 e) = vault.redeemInKind(shares, alice);
        assertGt(b, 0);
        assertGt(e, 0);
        // el vault sigue totalmente respaldado después de la salida
        assertGe(IERC20(WBTC).balanceOf(address(vault)), vault.totalSupply() * unitBtc / 1e18);
        assertGe(IERC20(WETH).balanceOf(address(vault)), vault.totalSupply() * unitEth / 1e18);
    }

    // ═══════════════════════════════ Ayudas ═══════════════════════════════

    function _roundTrip(address stable, uint256 amountIn) internal {
        uint256 gasBuy = gasleft();
        uint256 shares = _buy(stable, amountIn);
        gasBuy -= gasleft();

        uint256 inUsd = amountIn * 1e12;
        uint256 worth = guard.indexPriceUsd(unitBtc, unitEth) * shares / 1e18;
        uint256 costBps = worth >= inUsd ? 0 : (inUsd - worth) * 10_000 / inUsd;

        uint256 gasSell = gasleft();
        uint256 out = _sell(stable, shares);
        gasSell -= gasleft();
        uint256 roundBps = out >= amountIn ? 0 : (amountIn - out) * 10_000 / amountIn;

        console2.log("=== Monto (unidades de 6 dec):", amountIn);
        console2.log("DUOX recibidos (x1e18):", shares);
        console2.log("Costo de entrada total (bps, incluye 30 de comision):", costBps);
        console2.log("Recibido al vender:", out);
        console2.log("Costo ida y vuelta (bps, incluye 60 de comisiones):", roundBps);
        console2.log("Gas compra:", gasBuy);
        console2.log("Gas venta:", gasSell);

        // Comisiones (30 + 30 bps) + slippage real de los pools: debería quedar muy por debajo de 2%.
        assertLt(roundBps, 200, "costo ida y vuelta demasiado alto");
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(IERC20(stable).balanceOf(address(router)), 0);
    }

    function _buy(address stable, uint256 amountIn) internal returns (uint256 shares) {
        deal(stable, alice, amountIn);
        uint256 net = amountIn - (amountIn * router.buyFeeBps() + 9_999) / 10_000;
        uint256 half = net / 2;

        DuoxRouter.SwapStep[] memory steps = new DuoxRouter.SwapStep[](2);
        steps[0] = _uniStep(stable, half, _pathToBtc(stable));
        steps[1] = _uniStep(stable, net - half, _pathToEth(stable));

        vm.startPrank(alice);
        IERC20(stable).approve(address(router), amountIn);
        shares = router.buy(stable, amountIn, 1, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    function _sell(address stable, uint256 shares) internal returns (uint256 out) {
        (uint256 b, uint256 e) = vault.previewRedeem(shares);
        DuoxRouter.SwapStep[] memory steps = new DuoxRouter.SwapStep[](2);
        steps[0] = _uniStep(WBTC, b, _pathFromBtc(stable));
        steps[1] = _uniStep(WETH, e, _pathFromEth(stable));

        vm.startPrank(alice);
        vault.approve(address(router), shares);
        out = router.sell(shares, stable, 1, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    function _uniStep(address tokenIn, uint256 amountIn, bytes memory path)
        internal
        view
        returns (DuoxRouter.SwapStep memory)
    {
        // amountOutMinimum = 0 porque el Router controla contra el oráculo y el usuario fija su mínimo.
        bytes memory data = abi.encodeCall(
            ISwapRouter02.exactInput,
            (ISwapRouter02.ExactInputParams({
                    path: path, recipient: address(router), amountIn: amountIn, amountOutMinimum: 0
                }))
        );
        return DuoxRouter.SwapStep({target: UNISWAP_ROUTER, tokenIn: tokenIn, amountIn: amountIn, data: data});
    }

    // Rutas por los pools más profundos de Uniswap V3 en Arbitrum (0,05%), pasando por USDC si es USDT.
    function _pathToEth(address stable) internal pure returns (bytes memory) {
        if (stable == USDT) return abi.encodePacked(USDT, FEE_001, USDC, FEE_005, WETH);
        return abi.encodePacked(USDC, FEE_005, WETH);
    }

    function _pathToBtc(address stable) internal pure returns (bytes memory) {
        if (stable == USDT) return abi.encodePacked(USDT, FEE_001, USDC, FEE_005, WETH, FEE_005, WBTC);
        return abi.encodePacked(USDC, FEE_005, WETH, FEE_005, WBTC);
    }

    function _pathFromEth(address stable) internal pure returns (bytes memory) {
        if (stable == USDT) return abi.encodePacked(WETH, FEE_005, USDC, FEE_001, USDT);
        return abi.encodePacked(WETH, FEE_005, USDC);
    }

    function _pathFromBtc(address stable) internal pure returns (bytes memory) {
        if (stable == USDT) return abi.encodePacked(WBTC, FEE_005, WETH, FEE_005, USDC, FEE_001, USDT);
        return abi.encodePacked(WBTC, FEE_005, WETH, FEE_005, USDC);
    }

    function _checkFeed(address feed, string memory expected) internal view {
        string memory d = AggregatorV3Interface(feed).description();
        assertEq(d, expected, "el feed no es el esperado");
        (,,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        console2.log(d, "- segundos desde la ultima actualizacion:", block.timestamp - updatedAt);
    }
}
