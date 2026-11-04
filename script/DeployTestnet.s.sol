// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./DeployBase.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {TestnetToken, TestnetAggregator, TestnetDex} from "./testnet/TestnetMocks.sol";

/// @title Despliegue completo de DUOX en Arbitrum Sepolia (testnet)
/// @notice Despliega tokens, oráculos y un DEX de prueba, y después el sistema real con la misma lógica que
///         mainnet. Los precios de prueba los controla quien despliega (para simulacros de emergencia).
///
///   forge script script/DeployTestnet.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --account duox-testnet --broadcast
contract DeployTestnet is DeployBase {
    struct Mocks {
        TestnetToken wbtc;
        TestnetToken weth;
        TestnetToken usdc;
        TestnetToken usdt;
        TestnetAggregator seq;
        TestnetAggregator btc;
        TestnetAggregator eth;
        TestnetAggregator wrap;
        TestnetAggregator usdcFeed;
        TestnetAggregator usdtFeed;
        TestnetDex dex;
    }

    function run() external returns (Deployment memory d, Mocks memory m) {
        address safe = vm.envAddress("SAFE_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        (d, m) = deployAll(deployer, safe, guardian, treasury);
        vm.stopBroadcast();

        _log(d);
        console2.log("--- Contratos de prueba ---");
        console2.log("WBTC (prueba): ", address(m.wbtc));
        console2.log("WETH (prueba): ", address(m.weth));
        console2.log("USDC (prueba): ", address(m.usdc));
        console2.log("USDT (prueba): ", address(m.usdt));
        console2.log("DEX de prueba: ", address(m.dex));
        console2.log("Feed BTC/USD:  ", address(m.btc));
        console2.log("Feed ETH/USD:  ", address(m.eth));
        console2.log("Feed WBTC/BTC: ", address(m.wrap));
        console2.log("Feed USDC/USD: ", address(m.usdcFeed));
        console2.log("Feed USDT/USD: ", address(m.usdtFeed));
        console2.log("Sequencer:     ", address(m.seq));
    }

    /// @notice Despliegue completo; público para poder probarlo sin enviar transacciones.
    function deployAll(address deployer, address safe, address guardian, address treasury)
        public
        returns (Deployment memory d, Mocks memory m)
    {
        m = _deployMocks(deployer);

        Params memory p;
        p.name = "DUOX Index (Testnet)";
        p.symbol = "tDUOX";
        p.safe = safe;
        p.guardian = guardian;
        p.treasury = treasury;
        p.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(5 minutes)); // corto para poder practicar
        p.adminTransferDelay = 1 hours;
        p.wbtc = address(m.wbtc);
        p.weth = address(m.weth);
        p.unitBtc = 10_000;
        p.unitEth = 0; // se calcula 50/50 con los precios de prueba
        p.seqFeed = address(m.seq);
        p.btcFeed = address(m.btc);
        p.ethFeed = address(m.eth);
        p.wrapFeed = address(m.wrap);
        // En testnet nadie actualiza los feeds solos: 26 h y un `refresh()` diario alcanzan.
        p.btcStaleness = 26 hours;
        p.ethStaleness = 26 hours;
        p.wrapStaleness = 26 hours;
        p.stableStaleness = 26 hours;
        p.stables = new address[](2);
        p.stables[0] = address(m.usdc);
        p.stables[1] = address(m.usdt);
        p.stableDecimals = new uint8[](2);
        p.stableDecimals[0] = 6;
        p.stableDecimals[1] = 6;
        p.stableFeeds = new address[](2);
        p.stableFeeds[0] = address(m.usdcFeed);
        p.stableFeeds[1] = address(m.usdtFeed);
        p.swapTargets = new address[](1);
        p.swapTargets[0] = address(m.dex);
        p.vaultFeeBps = 5;
        p.buyFeeBps = 25;
        p.sellFeeBps = 30;
        p.supplyCap = 1_000_000e18;
        p.maxTradeUsd = 25_000e18;
        p.sellLimitUsd = 50_000e18;

        d = _deploy(p, deployer);
        _verify(d, p, deployer);
    }

    function _deployMocks(address owner) internal returns (Mocks memory m) {
        m.wbtc = new TestnetToken("Wrapped BTC (prueba)", "WBTC", 8, 0.05e8, owner);
        m.weth = new TestnetToken("Wrapped Ether (prueba)", "WETH", 18, 2e18, owner);
        m.usdc = new TestnetToken("USD Coin (prueba)", "USDC", 6, 10_000e6, owner);
        m.usdt = new TestnetToken("Tether USD (prueba)", "USDT", 6, 10_000e6, owner);

        m.seq = new TestnetAggregator(0, "Sequencer Uptime (prueba)", 0, owner);
        m.btc = new TestnetAggregator(8, "BTC / USD", 77_700e8, owner);
        m.eth = new TestnetAggregator(8, "ETH / USD", 2_293e8, owner);
        m.wrap = new TestnetAggregator(8, "WBTC / BTC", 1e8, owner);
        m.usdcFeed = new TestnetAggregator(8, "USDC / USD", 1e8, owner);
        m.usdtFeed = new TestnetAggregator(8, "USDT / USD", 1e8, owner);
        // El sequencer figura activo desde hace 2 h (fuera del período de gracia).
        m.seq.setStatus(0, block.timestamp - 2 hours);

        // DEX de prueba que cotiza con los mismos feeds
        m.dex = new TestnetDex(owner);
        m.dex.setToken(address(m.wbtc), m.btc, m.wrap);
        m.dex.setToken(address(m.weth), m.eth, AggregatorV3Interface(address(0)));
        m.dex.setToken(address(m.usdc), m.usdcFeed, AggregatorV3Interface(address(0)));
        m.dex.setToken(address(m.usdt), m.usdtFeed, AggregatorV3Interface(address(0)));
        m.wbtc.setMinter(address(m.dex), true);
        m.weth.setMinter(address(m.dex), true);
        m.usdc.setMinter(address(m.dex), true);
        m.usdt.setMinter(address(m.dex), true);
    }
}
