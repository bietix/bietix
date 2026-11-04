// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./DeployBase.sol";

/// @title Despliegue de BIETIX en Arbitrum One (o cualquier red con tokens y feeds reales)
/// @notice Lee toda la configuración del archivo .env (ver .env.example). Nada queda "por defecto" en lo
///         que importa: Safe, guardián, tesorería, antigüedad de feeds, unidades y límite de supply son obligatorios.
///
///   Simulación (no envía nada):
///     forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL
///   Despliegue real (con hardware wallet Ledger):
///     forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --ledger --broadcast --verify
contract Deploy is DeployBase {
    // Arbitrum One
    address internal constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address internal constant FEED_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant FEED_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant FEED_WBTC_BTC = 0x0017abAc5b6f291F9164e35B1234CA1D697f9CF4;
    address internal constant FEED_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address internal constant FEED_USDT_USD = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address internal constant FEED_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    uint256 internal constant ARBITRUM_ONE = 42161;

    function run() external returns (Deployment memory d) {
        Params memory p = _params();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        if (block.chainid == ARBITRUM_ONE) {
            // En mainnet, el Safe tiene que existir ya (ser un contrato), no una billetera común.
            _check(p.safe.code.length > 0, "SAFE_ADDRESS no es un contrato Safe desplegado");
            _check(p.unitEth > 0, "en mainnet UNIT_ETH debe fijarse explicitamente");
        }
        d = _deploy(p, deployer);
        vm.stopBroadcast();

        _verify(d, p, deployer);
        _log(d);
    }

    function _params() internal view returns (Params memory p) {
        p.name = vm.envOr("TOKEN_NAME", string("Bietix"));
        p.symbol = vm.envOr("TOKEN_SYMBOL", string("BIETIX"));

        p.safe = vm.envAddress("SAFE_ADDRESS");
        p.guardian = vm.envAddress("GUARDIAN_ADDRESS");
        p.treasury = vm.envAddress("TREASURY_ADDRESS");
        p.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(1 days));
        p.adminTransferDelay = uint48(vm.envOr("ADMIN_TRANSFER_DELAY", uint256(2 days)));

        p.wbtc = vm.envOr("WBTC_ADDRESS", WBTC);
        p.weth = vm.envOr("WETH_ADDRESS", WETH);
        p.unitBtc = vm.envOr("UNIT_BTC", uint256(10_000));
        p.unitEth = vm.envOr("UNIT_ETH", uint256(0));

        p.seqFeed = vm.envOr("FEED_SEQUENCER", FEED_SEQUENCER);
        p.btcFeed = vm.envOr("FEED_BTC_USD", FEED_BTC_USD);
        p.ethFeed = vm.envOr("FEED_ETH_USD", FEED_ETH_USD);
        p.wrapFeed = vm.envOr("FEED_WBTC_BTC", FEED_WBTC_BTC);
        // Antigüedad máxima: heartbeat publicado por Chainlink + tolerancia. Obligatorio (sección 4.9).
        p.btcStaleness = uint32(vm.envUint("BTC_STALENESS"));
        p.ethStaleness = uint32(vm.envUint("ETH_STALENESS"));
        p.wrapStaleness = uint32(vm.envUint("WBTC_BTC_STALENESS"));
        p.stableStaleness = uint32(vm.envUint("STABLE_STALENESS"));

        p.stables = new address[](2);
        p.stables[0] = USDC;
        p.stables[1] = USDT;
        p.stableDecimals = new uint8[](2);
        p.stableDecimals[0] = 6;
        p.stableDecimals[1] = 6;
        p.stableFeeds = new address[](2);
        p.stableFeeds[0] = FEED_USDC_USD;
        p.stableFeeds[1] = FEED_USDT_USD;

        p.swapTargets = vm.envAddress("SWAP_TARGETS", ",");

        p.vaultFeeBps = vm.envOr("VAULT_FEE_BPS", uint256(5));
        p.buyFeeBps = vm.envOr("BUY_FEE_BPS", uint256(25));
        p.sellFeeBps = vm.envOr("SELL_FEE_BPS", uint256(30));
        p.supplyCap = vm.envUint("SUPPLY_CAP"); // en BIETIX con 18 decimales
        p.maxTradeUsd = vm.envOr("MAX_TRADE_USD", uint256(25_000)) * 1e18;
        p.sellLimitUsd = vm.envOr("SELL_LIMIT_USD", uint256(50_000)) * 1e18;

        console2.log("Configuracion leida del .env. Safe:", p.safe);
    }
}
