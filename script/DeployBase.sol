// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BietixVault} from "../src/BietixVault.sol";
import {OracleGuard} from "../src/OracleGuard.sol";
import {BietixRouter} from "../src/BietixRouter.sol";
import {GuardianCanceller} from "../src/GuardianCanceller.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @title Lógica común de despliegue de BIETIX (mainnet y testnet)
/// @notice Despliega Timelock → OracleGuard → BietixVault → BietixRouter con toda la configuración inicial
///         en los constructores, y verifica al final que la billetera que despliega NO conserve ningún permiso.
/// @dev Ver Especificaciones Técnicas, secciones 2 (controles de acceso) y 6.10 (lista de verificación).
abstract contract DeployBase is Script {
    struct Params {
        // Identidad
        string name;
        string symbol;
        // Gobierno
        address safe; // Safe multisig
        address guardian; // billetera de respuesta rápida
        address treasury; // recibe las comisiones
        uint256 timelockDelay; // espera del Timelock (segundos)
        uint48 adminTransferDelay; // espera para transferir el rol de administrador
        uint256 guardianChangeDelay; // espera para que el Safe reemplace o quite al guardián del Timelock
        // Activos
        address wbtc;
        address weth;
        uint256 unitBtc; // sats por BIETIX
        uint256 unitEth; // wei por BIETIX (0 = calcular 50/50 al precio actual)
        // Oráculos
        address seqFeed;
        address btcFeed;
        address ethFeed;
        address wrapFeed;
        uint32 btcStaleness;
        uint32 ethStaleness;
        uint32 wrapStaleness;
        uint32 stableStaleness;
        address[] stables;
        uint8[] stableDecimals;
        address[] stableFeeds;
        // Router
        address[] swapTargets;
        // Comisiones y límites
        uint256 vaultFeeBps;
        uint256 buyFeeBps;
        uint256 sellFeeBps;
        uint256 supplyCap; // en BIETIX (18 decimales)
        uint256 maxTradeUsd; // USD con 18 decimales
        uint256 sellLimitUsd; // USD con 18 decimales
    }

    struct Deployment {
        TimelockController timelock;
        GuardianCanceller canceller;
        OracleGuard oracle;
        BietixVault vault;
        BietixRouter router;
    }

    error DeployCheckFailed(string what);

    // ═══════════════════════════════ Despliegue ═══════════════════════════════

    function _deploy(Params memory p, address deployer) internal returns (Deployment memory d) {
        _validateParams(p, deployer);

        // 1. Timelock: el Safe propone y ejecuta; el guardián puede cancelar a través de GuardianCanceller
        //    (así el Safe puede quitarle ese poder sin que el guardián lo vete). Nadie más.
        address[] memory proposers = new address[](1);
        proposers[0] = p.safe;
        address[] memory executors = new address[](1);
        executors[0] = p.safe;
        d.timelock = new TimelockController(p.timelockDelay, proposers, executors, deployer);
        d.canceller = new GuardianCanceller(d.timelock, p.safe, p.guardian, p.guardianChangeDelay);
        d.timelock.grantRole(d.timelock.CANCELLER_ROLE(), address(d.canceller));
        // Quien despliega renuncia de inmediato a la administración del Timelock.
        d.timelock.renounceRole(d.timelock.DEFAULT_ADMIN_ROLE(), deployer);

        // 2. OracleGuard con todos los feeds configurados desde el constructor.
        //    Los decimales de los activos se leen del propio token (WBTC = 8, WETH = 18).
        uint8 btcDec = IERC20Metadata(p.wbtc).decimals();
        uint8 ethDec = IERC20Metadata(p.weth).decimals();
        _check(btcDec == 8 && ethDec == 18, "decimales de WBTC/WETH");
        d.oracle = new OracleGuard(
            address(d.timelock),
            p.adminTransferDelay,
            p.safe,
            p.guardian,
            btcDec,
            ethDec,
            AggregatorV3Interface(p.seqFeed),
            _feedInits(p),
            _stableInits(p)
        );

        // 3. Unidades por token: si no se fijaron, 50/50 al precio actual del oráculo
        if (p.unitEth == 0) {
            uint256 btcPartUsd = d.oracle.wbtcUsd() * p.unitBtc / 1e8;
            p.unitEth = btcPartUsd * 1e18 / d.oracle.ethUsd();
        }

        // 4. Vault (núcleo inmutable)
        d.vault = new BietixVault(
            p.name,
            p.symbol,
            BietixVault.Config({
                assetBtc: IERC20(p.wbtc),
                assetEth: IERC20(p.weth),
                unitBtc: p.unitBtc,
                unitEth: p.unitEth,
                admin: address(d.timelock),
                adminTransferDelay: p.adminTransferDelay,
                safe: p.safe,
                guardian: p.guardian,
                treasury: p.treasury,
                mintFeeBps: p.vaultFeeBps,
                supplyCap: p.supplyCap
            })
        );

        // 5. Router con stablecoins y agregadores habilitados desde el constructor
        d.router = new BietixRouter(
            BietixRouter.Config({
                vault: d.vault,
                oracle: d.oracle,
                admin: address(d.timelock),
                adminTransferDelay: p.adminTransferDelay,
                safe: p.safe,
                guardian: p.guardian,
                treasury: p.treasury,
                buyFeeBps: p.buyFeeBps,
                sellFeeBps: p.sellFeeBps,
                maxTradeUsd: p.maxTradeUsd,
                sellLimitUsd: p.sellLimitUsd,
                stables: p.stables,
                swapTargets: p.swapTargets
            })
        );
    }

    // ═══════════════════════ Verificación posterior (6.10) ═══════════════════════

    function _verify(Deployment memory d, Params memory p, address deployer) internal view {
        TimelockController t = d.timelock;

        // Timelock
        _check(t.getMinDelay() == p.timelockDelay, "espera del timelock");
        _check(t.hasRole(t.PROPOSER_ROLE(), p.safe), "safe proponente");
        _check(t.hasRole(t.EXECUTOR_ROLE(), p.safe), "safe ejecutor");
        _check(t.hasRole(t.CANCELLER_ROLE(), p.safe), "safe cancelador");
        _check(!t.hasRole(t.CANCELLER_ROLE(), p.guardian), "guardian cancelador directo");
        GuardianCanceller c = d.canceller;
        _check(t.hasRole(t.CANCELLER_ROLE(), address(c)), "canceller cancelador");
        _check(
            address(c.TIMELOCK()) == address(t) && c.SAFE() == p.safe && c.guardian() == p.guardian
                && c.CHANGE_DELAY() == p.guardianChangeDelay,
            "configuracion del canceller"
        );
        _check(!t.hasRole(t.DEFAULT_ADMIN_ROLE(), deployer), "deployer sigue admin del timelock");
        _check(!t.hasRole(t.PROPOSER_ROLE(), deployer), "deployer proponente");
        _check(!t.hasRole(t.EXECUTOR_ROLE(), deployer), "deployer ejecutor");
        _check(!t.hasRole(t.CANCELLER_ROLE(), deployer), "deployer cancelador");
        _check(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(t)), "timelock se administra a si mismo");

        // Vault
        BietixVault v = d.vault;
        _check(v.defaultAdmin() == address(t), "admin del vault = timelock");
        _check(
            v.hasRole(v.UNPAUSER_ROLE(), p.safe) && v.hasRole(v.GUARDIAN_ROLE(), p.safe),
            "roles del safe en vault"
        );
        _check(v.hasRole(v.GUARDIAN_ROLE(), p.guardian), "guardian en vault");
        _check(
            !v.hasRole(v.GUARDIAN_ROLE(), deployer) && !v.hasRole(v.UNPAUSER_ROLE(), deployer),
            "deployer en vault"
        );
        _check(address(v.ASSET_BTC()) == p.wbtc && address(v.ASSET_ETH()) == p.weth, "activos del vault");
        _check(v.treasury() == p.treasury, "tesoreria del vault");
        _check(v.totalSupply() == 0, "supply inicial");

        // OracleGuard
        OracleGuard o = d.oracle;
        _check(o.defaultAdmin() == address(t), "admin del oraculo = timelock");
        _check(
            !o.hasRole(o.GUARDIAN_ROLE(), deployer) && !o.hasRole(o.SAFE_ROLE(), deployer),
            "deployer en oraculo"
        );
        _check(
            o.hasRole(o.SAFE_ROLE(), p.safe) && o.hasRole(o.GUARDIAN_ROLE(), p.safe)
                && o.hasRole(o.GUARDIAN_ROLE(), p.guardian),
            "roles del oraculo"
        );
        _check(o.indexPriceUsd(v.UNIT_BTC(), v.UNIT_ETH()) > 0, "precio del indice");
        for (uint256 i; i < p.stables.length; i++) {
            _check(o.stableUsd(p.stables[i]) > 0, "precio de stable");
        }

        // Router
        BietixRouter r = d.router;
        _check(r.defaultAdmin() == address(t), "admin del router = timelock");
        _check(
            !r.hasRole(r.GUARDIAN_ROLE(), deployer) && !r.hasRole(r.UNPAUSER_ROLE(), deployer),
            "deployer en router"
        );
        _check(
            r.hasRole(r.UNPAUSER_ROLE(), p.safe) && r.hasRole(r.GUARDIAN_ROLE(), p.safe)
                && r.hasRole(r.GUARDIAN_ROLE(), p.guardian),
            "roles del router"
        );
        _check(address(r.VAULT()) == address(v) && address(r.oracle()) == address(o), "conexiones del router");
        _check(r.treasury() == p.treasury, "tesoreria del router");
        for (uint256 i; i < p.stables.length; i++) {
            _check(r.isStable(p.stables[i]), "stable habilitada");
        }
        for (uint256 i; i < p.swapTargets.length; i++) {
            _check(r.isSwapTarget(p.swapTargets[i]), "agregador habilitado");
        }
    }

    function _log(Deployment memory d) internal view {
        console2.log("==================== BIETIX desplegado ====================");
        console2.log("Red (chainid):     ", block.chainid);
        console2.log("TimelockController:", address(d.timelock));
        console2.log("GuardianCanceller: ", address(d.canceller));
        console2.log("OracleGuard:       ", address(d.oracle));
        console2.log("BietixVault (BIETIX):  ", address(d.vault));
        console2.log("BietixRouter:        ", address(d.router));
        console2.log("UNIT_BTC (sats):   ", d.vault.UNIT_BTC());
        console2.log("UNIT_ETH (wei):    ", d.vault.UNIT_ETH());
        console2.log(
            "Precio 1 BIETIX (USD x1e18):", d.oracle.indexPriceUsd(d.vault.UNIT_BTC(), d.vault.UNIT_ETH())
        );
        console2.log("Verificacion de permisos: OK (la billetera que desplego no conserva ningun rol)");
        console2.log("==========================================================");
    }

    // ═══════════════════════════════ Internas ═══════════════════════════════

    function _validateParams(Params memory p, address deployer) internal pure {
        _check(
            p.safe != address(0) && p.guardian != address(0) && p.treasury != address(0), "direcciones vacias"
        );
        _check(p.safe != deployer && p.guardian != deployer, "safe/guardian no pueden ser quien despliega");
        _check(p.safe != p.guardian, "safe y guardian deben ser distintos");
        _check(
            p.guardianChangeDelay >= p.timelockDelay, "espera de cambio de guardian menor que la del timelock"
        );
        _check(
            p.stables.length == p.stableDecimals.length && p.stables.length == p.stableFeeds.length, "stables"
        );
        _check(p.swapTargets.length > 0, "falta al menos un agregador");
        _check(p.unitBtc > 0, "unitBtc");
    }

    function _feedInits(Params memory p) internal pure returns (OracleGuard.FeedInit[] memory f) {
        f = new OracleGuard.FeedInit[](3);
        f[0] = OracleGuard.FeedInit(
            keccak256("BTC_USD"), AggregatorV3Interface(p.btcFeed), p.btcStaleness, 1_000e18, 10_000_000e18
        );
        f[1] = OracleGuard.FeedInit(
            keccak256("ETH_USD"), AggregatorV3Interface(p.ethFeed), p.ethStaleness, 50e18, 1_000_000e18
        );
        f[2] = OracleGuard.FeedInit(
            keccak256("WBTC_BTC"), AggregatorV3Interface(p.wrapFeed), p.wrapStaleness, 0.5e18, 1.5e18
        );
    }

    function _stableInits(Params memory p) internal pure returns (OracleGuard.StableInit[] memory s) {
        s = new OracleGuard.StableInit[](p.stables.length);
        for (uint256 i; i < p.stables.length; i++) {
            s[i] = OracleGuard.StableInit(
                p.stables[i],
                p.stableDecimals[i],
                AggregatorV3Interface(p.stableFeeds[i]),
                p.stableStaleness,
                0.5e18,
                1.5e18
            );
        }
    }

    function _check(bool ok, string memory what) internal pure {
        if (!ok) revert DeployCheckFailed(what);
    }
}
