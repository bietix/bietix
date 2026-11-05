// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BietixRouter} from "../../src/BietixRouter.sol";
import {ArbitrumForkBase} from "./ArbitrumFork.t.sol";

/// @title Compra y venta reales a través de KyberSwap sobre un fork de Arbitrum One
/// @notice Pide rutas en vivo a la API pública de KyberSwap con la misma lógica que el sitio
///         (script/kyber/route.mjs → frontend/netlify/lib/kyber.mjs) y las ejecuta en el BietixRouter.
///         Necesita red, Node 18+ y permiso de ffi, así que NO corre en la integración continua. Correr con:
///
///         KYBER_FORK=true forge test --match-contract KyberForkTest --ffi -vv
///
///         (ARBITRUM_RPC_URL en el .env, igual que las demás pruebas de fork)
contract KyberForkTest is ArbitrumForkBase {
    address internal constant KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    uint256 internal constant SLIPPAGE_BPS = 100;

    bool internal enabled;

    function setUp() public override {
        super.setUp();
        enabled = forked && vm.envOr("KYBER_FORK", false);
        if (!enabled) return;
        vm.prank(timelock);
        router.addSwapTarget(KYBER_ROUTER);
    }

    modifier onlyKyber() {
        if (!enabled) {
            console2.log("Sin KYBER_FORK=true y ARBITRUM_RPC_URL: prueba de KyberSwap salteada");
            vm.skip(true);
        }
        _;
    }

    function test_kyber_buyAndSell_USDC() public onlyKyber {
        _roundTripKyber(USDC, 1_000e6);
    }

    function test_kyber_buyAndSell_USDT() public onlyKyber {
        _roundTripKyber(USDT, 1_000e6);
    }

    function test_kyber_buyAndSell_USDC_10k() public onlyKyber {
        _roundTripKyber(USDC, 10_000e6);
    }

    function _roundTripKyber(address stable, uint256 amountIn) internal {
        uint256 shares = _kyberBuy(stable, amountIn);
        uint256 out = _kyberSell(stable, shares);
        console2.log("Ida y vuelta: entrada", amountIn);
        console2.log("Ida y vuelta: salida ", out);
        console2.log("Costo total (bps)", (amountIn - out) * 10_000 / amountIn);
        assertGt(out, amountIn * 9_800 / 10_000, "ida y vuelta costo mas de 2%");
    }

    function _kyberBuy(address stable, uint256 amountIn) internal returns (uint256 shares) {
        deal(stable, alice, amountIn);
        uint256 net = amountIn - (amountIn * router.buyFeeBps() + 9_999) / 10_000;
        BietixRouter.SwapStep[] memory steps = new BietixRouter.SwapStep[](2);
        uint256 outBtc;
        uint256 outEth;
        (steps[0], outBtc) = _kyberStep(stable, WBTC, net / 2);
        (steps[1], outEth) = _kyberStep(stable, WETH, net - net / 2);
        uint256 quotedShares = router.sharesFor(outBtc, outEth);
        uint256 minShares = quotedShares * (10_000 - SLIPPAGE_BPS) / 10_000;

        vm.startPrank(alice);
        IERC20(stable).approve(address(router), amountIn);
        shares = router.buy(stable, amountIn, minShares, steps, block.timestamp, alice);
        vm.stopPrank();
        assertGt(shares, 0);
        _assertRouterClean(stable);
        // Si lo ejecutado queda por debajo de lo cotizado, la diferencia es por el desfase del fork, no de la ruta.
        _logSlip("Compra: ejecutado vs cotizado (bps, + = peor)", quotedShares, shares);

        uint256 paidUsd = guard.stableValueUsd(stable, amountIn);
        uint256 gotUsd = guard.indexPriceUsd(unitBtc, unitEth) * shares / 1e18;
        console2.log("Compra: USD pagados (1e18)", paidUsd);
        console2.log("Compra: USD en BIETIX (1e18)", gotUsd);
        assertGt(gotUsd, paidUsd * 9_850 / 10_000, "la compra costo mas de 1,5%");
    }

    function _kyberSell(address stable, uint256 shares) internal returns (uint256 out) {
        (uint256 b, uint256 e) = vault.previewRedeem(shares);
        BietixRouter.SwapStep[] memory steps = new BietixRouter.SwapStep[](2);
        uint256 outB;
        uint256 outE;
        (steps[0], outB) = _kyberStep(WBTC, stable, b);
        (steps[1], outE) = _kyberStep(WETH, stable, e);
        uint256 gross = outB + outE;
        uint256 minOut =
            (gross - (gross * router.sellFeeBps() + 9_999) / 10_000) * (10_000 - SLIPPAGE_BPS) / 10_000;

        vm.startPrank(alice);
        vault.approve(address(router), shares);
        out = router.sell(shares, stable, minOut, steps, block.timestamp, alice);
        vm.stopPrank();
        _assertRouterClean(stable);
        uint256 quotedNet = gross - (gross * router.sellFeeBps() + 9_999) / 10_000;
        _logSlip("Venta: ejecutado vs cotizado (bps, + = peor)", quotedNet, out);
    }

    /// @dev Pide la ruta a KyberSwap (con el Router como emisor y receptor) vía script/kyber/route.mjs.
    function _kyberStep(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (BietixRouter.SwapStep memory step, uint256 amountOut)
    {
        string[] memory cmd = new string[](7);
        cmd[0] = "node";
        cmd[1] = "script/kyber/route.mjs";
        cmd[2] = vm.toString(address(router));
        cmd[3] = vm.toString(tokenIn);
        cmd[4] = vm.toString(tokenOut);
        cmd[5] = vm.toString(amountIn);
        cmd[6] = vm.toString(SLIPPAGE_BPS);
        (address to, uint256 out, bytes memory data) = abi.decode(vm.ffi(cmd), (address, uint256, bytes));
        assertEq(to, KYBER_ROUTER, "destino inesperado");
        step = BietixRouter.SwapStep({target: to, tokenIn: tokenIn, amountIn: amountIn, data: data});
        amountOut = out;
    }

    function _logSlip(string memory what, uint256 quoted, uint256 got) internal pure {
        if (got >= quoted) console2.log(what, uint256(0));
        else console2.log(what, (quoted - got) * 10_000 / quoted);
    }

    function _assertRouterClean(address stable) internal view {
        assertEq(IERC20(stable).balanceOf(address(router)), 0, "stable retenida");
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0, "WBTC retenido");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "WETH retenido");
        assertEq(IERC20(stable).allowance(address(router), KYBER_ROUTER), 0, "aprobacion abierta");
    }
}
