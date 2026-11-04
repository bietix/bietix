// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DuoxRouter} from "../../src/DuoxRouter.sol";
import {DuoxVault} from "../../src/DuoxVault.sol";
import {OracleGuard} from "../../src/OracleGuard.sol";
import {TestnetToken, TestnetDex, TestnetAggregator} from "./TestnetMocks.sol";

/// @title Operar DUOX en testnet desde la terminal
/// @notice Lee las direcciones del .env (TESTNET_*). Ejemplos:
///   Ver estado:   forge script script/testnet/Interact.s.sol --sig "status()" --rpc-url arbitrum_sepolia
///   Comprar $100: forge script script/testnet/Interact.s.sol --sig "buy(uint256)" 100 --rpc-url arbitrum_sepolia --account duox-testnet --broadcast
///   Vender todo:  forge script script/testnet/Interact.s.sol --sig "sellAll()" --rpc-url arbitrum_sepolia --account duox-testnet --broadcast
///   Salida In-Kind: forge script script/testnet/Interact.s.sol --sig "exitInKind()" --rpc-url arbitrum_sepolia --account duox-testnet --broadcast
///   Refrescar feeds: forge script script/testnet/Interact.s.sol --sig "refreshFeeds()" --rpc-url arbitrum_sepolia --account duox-testnet --broadcast
contract Interact is Script {
    DuoxRouter internal router;
    DuoxVault internal vault;
    OracleGuard internal oracle;
    TestnetDex internal dex;
    TestnetToken internal usdc;
    TestnetToken internal wbtc;
    TestnetToken internal weth;

    uint256 internal constant SLIPPAGE_BPS = 100; // acepto hasta 1% menos de lo cotizado

    function _load() internal {
        router = DuoxRouter(vm.envAddress("TESTNET_ROUTER"));
        vault = DuoxVault(vm.envAddress("TESTNET_VAULT"));
        oracle = OracleGuard(vm.envAddress("TESTNET_ORACLE"));
        dex = TestnetDex(vm.envAddress("TESTNET_DEX"));
        usdc = TestnetToken(vm.envAddress("TESTNET_USDC"));
        wbtc = TestnetToken(vm.envAddress("TESTNET_WBTC"));
        weth = TestnetToken(vm.envAddress("TESTNET_WETH"));
    }

    /// @notice Muestra precio, respaldo y saldos (no envía nada).
    function status() external {
        _load();
        (, address user,) = vm.readCallers();
        uint256 supply = vault.totalSupply();
        console2.log("===== Estado de DUOX (testnet) =====");
        console2.log("Precio 1 DUOX (USD x1e18):", oracle.indexPriceUsd(vault.UNIT_BTC(), vault.UNIT_ETH()));
        console2.log("DUOX en circulacion (x1e18):", supply);
        console2.log("WBTC en el vault (sats):    ", wbtc.balanceOf(address(vault)));
        console2.log("WBTC requerido (sats):      ", supply * vault.UNIT_BTC() / 1e18);
        console2.log("WETH en el vault (wei):     ", weth.balanceOf(address(vault)));
        console2.log("WETH requerido (wei):       ", supply * vault.UNIT_ETH() / 1e18);
        console2.log("--- Tu billetera:", user);
        console2.log("DUOX (x1e18):", vault.balanceOf(user));
        console2.log("USDC (x1e6): ", usdc.balanceOf(user));
        console2.log("WBTC (sats): ", wbtc.balanceOf(user));
        console2.log("WETH (wei):  ", weth.balanceOf(user));
    }

    /// @notice Compra DUOX por `usd` dólares de USDC de prueba (pide a la faucet si hace falta).
    function buy(uint256 usd) external {
        _load();
        uint256 amountIn = usd * 1e6;
        vm.startBroadcast();
        (, address user,) = vm.readCallers();
        if (usdc.balanceOf(user) < amountIn) usdc.faucet();

        uint256 net = amountIn - (amountIn * router.buyFeeBps() + 9_999) / 10_000;
        uint256 half = net / 2;
        uint256 btcQuote = dex.quote(address(usdc), half, address(wbtc));
        uint256 ethQuote = dex.quote(address(usdc), net - half, address(weth));

        DuoxRouter.SwapStep[] memory steps = new DuoxRouter.SwapStep[](2);
        steps[0] = _step(address(usdc), half, address(wbtc), _min(btcQuote));
        steps[1] = _step(address(usdc), net - half, address(weth), _min(ethQuote));
        uint256 minShares = _min(router.sharesFor(btcQuote, ethQuote));

        usdc.approve(address(router), amountIn);
        uint256 shares =
            router.buy(address(usdc), amountIn, minShares, steps, block.timestamp + 10 minutes, user);
        vm.stopBroadcast();

        console2.log("Compra OK. DUOX recibidos (x1e18):", shares);
    }

    /// @notice Vende todos tus DUOX por USDC de prueba.
    function sellAll() external {
        _load();
        vm.startBroadcast();
        (, address user,) = vm.readCallers();
        uint256 shares = vault.balanceOf(user);
        require(shares > 0, "no tenes DUOX");
        (uint256 b, uint256 e) = vault.previewRedeem(shares);
        uint256 qb = dex.quote(address(wbtc), b, address(usdc));
        uint256 qe = dex.quote(address(weth), e, address(usdc));

        DuoxRouter.SwapStep[] memory steps = new DuoxRouter.SwapStep[](2);
        steps[0] = _step(address(wbtc), b, address(usdc), _min(qb));
        steps[1] = _step(address(weth), e, address(usdc), _min(qe));
        uint256 minOut = _min((qb + qe) - ((qb + qe) * router.sellFeeBps() + 9_999) / 10_000);

        vault.approve(address(router), shares);
        uint256 out = router.sell(shares, address(usdc), minOut, steps, block.timestamp + 10 minutes, user);
        vm.stopBroadcast();

        console2.log("Venta OK. USDC recibidos (x1e6):", out);
    }

    /// @notice Salida In-Kind: quema todos tus DUOX y recibís WBTC + WETH directo del vault.
    function exitInKind() external {
        _load();
        vm.startBroadcast();
        (, address user,) = vm.readCallers();
        uint256 shares = vault.balanceOf(user);
        require(shares > 0, "no tenes DUOX");
        (uint256 b, uint256 e) = vault.redeemInKind(shares, user);
        vm.stopBroadcast();
        console2.log("Salida In-Kind OK. WBTC (sats):", b);
        console2.log("WETH (wei):", e);
    }

    /// @notice Refresca los feeds de prueba (hay que hacerlo al menos una vez por día).
    function refreshFeeds() external {
        vm.startBroadcast();
        TestnetAggregator(vm.envAddress("TESTNET_FEED_BTC")).refresh();
        TestnetAggregator(vm.envAddress("TESTNET_FEED_ETH")).refresh();
        TestnetAggregator(vm.envAddress("TESTNET_FEED_WBTC_BTC")).refresh();
        TestnetAggregator(vm.envAddress("TESTNET_FEED_USDC")).refresh();
        TestnetAggregator(vm.envAddress("TESTNET_FEED_USDT")).refresh();
        vm.stopBroadcast();
        console2.log("Feeds refrescados");
    }

    function _step(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut)
        internal
        view
        returns (DuoxRouter.SwapStep memory)
    {
        return DuoxRouter.SwapStep({
            target: address(dex),
            tokenIn: tokenIn,
            amountIn: amountIn,
            data: abi.encodeCall(TestnetDex.swap, (tokenIn, amountIn, tokenOut, minOut, address(router)))
        });
    }

    function _min(uint256 x) internal pure returns (uint256) {
        return x * (10_000 - SLIPPAGE_BPS) / 10_000;
    }
}
