// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployBase} from "../../script/DeployBase.sol";
import {BietixRouter} from "../../src/BietixRouter.sol";
import {BietixVault} from "../../src/BietixVault.sol";
import {OracleGuard} from "../../src/OracleGuard.sol";
import {GuardianCanceller} from "../../src/GuardianCanceller.sol";
import {TestnetDex} from "../../script/testnet/TestnetMocks.sol";

/// @notice Prueba los scripts de despliegue y el gobierno resultante (Safe + Timelock + guardián).
contract DeployTest is Test {
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    DeployTestnet internal script;
    DeployBase.Deployment internal d;
    DeployTestnet.Mocks internal m;

    function setUp() public {
        vm.warp(30 days);
        script = new DeployTestnet();
        (d, m) = script.deployAll(address(script), safe, guardian, treasury);
    }

    // ─────────────────────────── Resultado del despliegue ───────────────────────────

    function test_deployerHasNoPermissions() public view {
        address deployer = address(script);
        TimelockController t = d.timelock;
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(t.hasRole(t.PROPOSER_ROLE(), deployer));
        assertFalse(d.vault.hasRole(d.vault.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(d.vault.hasRole(d.vault.GUARDIAN_ROLE(), deployer));
        assertFalse(d.router.hasRole(d.router.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(d.oracle.hasRole(d.oracle.DEFAULT_ADMIN_ROLE(), deployer));
        assertEq(d.vault.defaultAdmin(), address(t));
        assertEq(d.router.defaultAdmin(), address(t));
        assertEq(d.oracle.defaultAdmin(), address(t));
    }

    function test_unitsAre5050() public view {
        uint256 btcUsd = d.oracle.basketValueUsd(d.vault.UNIT_BTC(), 0);
        uint256 ethUsd = d.oracle.basketValueUsd(0, d.vault.UNIT_ETH());
        assertApproxEqRel(btcUsd, ethUsd, 0.0001e18); // diferencia < 0,01%
    }

    function test_buyAndSellOnTestnetSetup() public {
        vm.prank(alice);
        m.usdc.faucet();
        uint256 amountIn = 1_000e6;
        uint256 net = amountIn - (amountIn * 25 + 9_999) / 10_000;
        uint256 half = net / 2;

        BietixRouter.SwapStep[] memory steps = new BietixRouter.SwapStep[](2);
        steps[0] = _dexStep(address(m.usdc), half, address(m.wbtc));
        steps[1] = _dexStep(address(m.usdc), net - half, address(m.weth));

        vm.startPrank(alice);
        m.usdc.approve(address(d.router), amountIn);
        uint256 shares = d.router.buy(address(m.usdc), amountIn, 1, steps, block.timestamp, alice);
        vm.stopPrank();
        assertGt(shares, 0);

        (uint256 b, uint256 e) = d.vault.previewRedeem(shares);
        BietixRouter.SwapStep[] memory sellSteps = new BietixRouter.SwapStep[](2);
        sellSteps[0] = _dexStep(address(m.wbtc), b, address(m.usdc));
        sellSteps[1] = _dexStep(address(m.weth), e, address(m.usdc));
        uint256 before = m.usdc.balanceOf(alice);
        vm.startPrank(alice);
        d.vault.approve(address(d.router), shares);
        uint256 out = d.router.sell(shares, address(m.usdc), 1, sellSteps, block.timestamp, alice);
        vm.stopPrank();
        assertEq(m.usdc.balanceOf(alice) - before, out);
        assertGt(out, 990e6); // 0,6% comisiones + 0,2% spread del DEX de prueba + polvo
    }

    // ─────────────────────────── Gobierno ───────────────────────────

    function test_governance_safeProposesTimelockExecutes() public {
        TimelockController t = d.timelock;
        bytes memory call = abi.encodeCall(BietixVault.increaseSupplyCap, (2_000_000e18));
        uint256 delay = t.getMinDelay();

        vm.prank(safe);
        t.schedule(address(d.vault), 0, call, bytes32(0), bytes32("cap"), delay);

        vm.prank(safe);
        vm.expectRevert(); // todavía no pasó la espera
        t.execute(address(d.vault), 0, call, bytes32(0), bytes32("cap"));

        vm.warp(block.timestamp + delay);
        m.btc.refresh();
        vm.prank(safe);
        t.execute(address(d.vault), 0, call, bytes32(0), bytes32("cap"));
        assertEq(d.vault.supplyCap(), 2_000_000e18);
    }

    function test_governance_guardianCancelsMaliciousProposal() public {
        TimelockController t = d.timelock;
        bytes memory call = abi.encodeCall(BietixVault.setTreasury, (makeAddr("atacante")));
        uint256 delay = t.getMinDelay();
        vm.prank(safe); // el Safe fue comprometido y propone cambiar la tesorería
        t.schedule(address(d.vault), 0, call, bytes32(0), bytes32("malo"), delay);
        bytes32 id = t.hashOperation(address(d.vault), 0, call, bytes32(0), bytes32("malo"));
        assertTrue(t.isOperationPending(id));

        // el guardián cancela a través de GuardianCanceller (no tiene el rol directo en el Timelock)
        vm.prank(guardian);
        vm.expectRevert();
        t.cancel(id);
        vm.prank(guardian);
        d.canceller.cancel(id);
        assertFalse(t.isOperation(id));
        assertEq(d.vault.treasury(), treasury);
    }

    /// Regresión de la revisión interna (M-2): el guardián no puede vetar para siempre su propia remoción.
    function test_governance_safeCanRemoveGuardianVeto() public {
        GuardianCanceller c = d.canceller;
        vm.prank(guardian);
        vm.expectRevert(GuardianCanceller.NotSafe.selector);
        c.proposeGuardian(guardian);

        vm.prank(safe); // llamada directa: no pasa por el Timelock, el guardián no puede cancelarla
        c.proposeGuardian(address(0));
        vm.expectRevert(abi.encodeWithSelector(GuardianCanceller.ChangeNotReady.selector, c.changeReadyAt()));
        c.applyGuardianChange();

        // mientras corre la espera, el guardián todavía puede vetar
        TimelockController t = d.timelock;
        bytes memory call = abi.encodeCall(BietixVault.setMintFee, (10));
        uint256 delay = t.getMinDelay();
        vm.prank(safe);
        t.schedule(address(d.vault), 0, call, bytes32(0), bytes32(0), delay);
        bytes32 id = t.hashOperation(address(d.vault), 0, call, bytes32(0), bytes32(0));
        vm.prank(guardian);
        c.cancel(id);

        vm.warp(block.timestamp + c.CHANGE_DELAY());
        c.applyGuardianChange(); // cualquiera puede aplicarlo
        assertEq(c.guardian(), address(0));

        vm.prank(safe);
        t.schedule(address(d.vault), 0, call, bytes32(0), bytes32(0), delay);
        vm.prank(guardian);
        vm.expectRevert(GuardianCanceller.NotGuardian.selector);
        c.cancel(id);
        vm.warp(block.timestamp + delay);
        vm.prank(safe);
        t.execute(address(d.vault), 0, call, bytes32(0), bytes32(0));
        assertEq(d.vault.mintFeeBps(), 10);
    }

    function test_governance_guardianChangeCanBeWithdrawnAndGuardianCanResign() public {
        GuardianCanceller c = d.canceller;
        address g2 = makeAddr("guardian2");
        vm.prank(safe);
        c.proposeGuardian(g2);
        vm.prank(safe);
        c.cancelGuardianChange();
        vm.expectRevert(GuardianCanceller.NoPendingChange.selector);
        c.applyGuardianChange();
        assertEq(c.guardian(), guardian);

        vm.prank(alice);
        vm.expectRevert(GuardianCanceller.NotGuardian.selector);
        c.resign();
        vm.prank(guardian);
        c.resign();
        assertEq(c.guardian(), address(0));
    }

    function test_governance_onlySafeCanPropose() public {
        TimelockController t = d.timelock;
        bytes memory call = abi.encodeCall(BietixVault.setMintFee, (100));
        address[3] memory notAllowed = [guardian, alice, address(script)];
        uint256 delay = t.getMinDelay();
        for (uint256 i; i < notAllowed.length; i++) {
            vm.prank(notAllowed[i]);
            vm.expectRevert();
            t.schedule(address(d.vault), 0, call, bytes32(0), bytes32(0), delay);
        }
    }

    function test_governance_nobodyCanChangeParamsDirectly() public {
        vm.prank(safe);
        vm.expectRevert();
        d.vault.setMintFee(100);
        vm.prank(guardian);
        vm.expectRevert();
        d.router.setBuyFee(100);
        vm.prank(address(script));
        vm.expectRevert();
        d.oracle.relaxMargin(300);
    }

    // ─────────────────────────── Simulacros de emergencia ───────────────────────────

    function test_drill_wrapperDepeg() public {
        vm.prank(alice);
        m.usdc.faucet();
        vm.prank(address(script)); // quien desplegó controla los precios de prueba
        m.wrap.setAnswer(0.97e8);
        assertTrue(d.oracle.wrapperAlert());
        uint256 net = 1_000e6 - 2.5e6;
        BietixRouter.SwapStep[] memory steps = new BietixRouter.SwapStep[](2);
        steps[0] = _dexStep(address(m.usdc), net / 2, address(m.wbtc));
        steps[1] = _dexStep(address(m.usdc), net - net / 2, address(m.weth));
        vm.startPrank(alice);
        m.usdc.approve(address(d.router), 1_000e6);
        vm.expectRevert(OracleGuard.WrapperDepegged.selector);
        d.router.buy(address(m.usdc), 1_000e6, 1, steps, block.timestamp, alice);
        vm.stopPrank();
    }

    function test_drill_sequencerDown() public {
        vm.prank(address(script));
        m.seq.setStatus(1, block.timestamp);
        vm.expectRevert(OracleGuard.SequencerDown.selector);
        d.oracle.checkSequencer();
        vm.prank(address(script));
        m.seq.setStatus(0, block.timestamp);
        vm.expectRevert(OracleGuard.GracePeriodNotOver.selector);
        d.oracle.checkSequencer();
    }

    function test_testnetFaucetCooldown() public {
        vm.startPrank(alice);
        m.wbtc.faucet();
        vm.expectRevert();
        m.wbtc.faucet();
        vm.stopPrank();
        assertEq(m.wbtc.balanceOf(alice), 0.05e8);
    }

    // ─────────────────────────── Ayudas ───────────────────────────

    function _dexStep(address tokenIn, uint256 amountIn, address tokenOut)
        internal
        view
        returns (BietixRouter.SwapStep memory)
    {
        return BietixRouter.SwapStep({
            target: address(m.dex),
            tokenIn: tokenIn,
            amountIn: amountIn,
            data: abi.encodeCall(TestnetDex.swap, (tokenIn, amountIn, tokenOut, 0, address(d.router)))
        });
    }
}

/// @notice Simulación del script de mainnet sobre un fork de Arbitrum One (se saltea sin RPC).
contract DeployMainnetForkTest is Test {
    function test_mainnetScript_dryRun() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        // En el fork se usa un contrato cualquiera como "Safe" (en mainnet debe ser el Safe real).
        address fakeSafe = address(new FakeSafe());
        vm.setEnv("SAFE_ADDRESS", vm.toString(fakeSafe));
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(makeAddr("guardian")));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(makeAddr("treasury")));
        vm.setEnv("BTC_STALENESS", "93600");
        vm.setEnv("ETH_STALENESS", "93600");
        vm.setEnv("WBTC_BTC_STALENESS", "93600");
        vm.setEnv("STABLE_STALENESS", "93600");
        vm.setEnv("UNIT_ETH", "3387580037069217");
        vm.setEnv("SUPPLY_CAP", "3200000000000000000000");
        vm.setEnv("SWAP_TARGETS", "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45");

        Deploy deployScript = new Deploy();
        DeployBase.Deployment memory dep = deployScript.run();
        assertEq(dep.vault.supplyCap(), 3_200e18);
        assertEq(address(dep.vault.ASSET_BTC()), 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
        assertGt(dep.oracle.indexPriceUsd(dep.vault.UNIT_BTC(), dep.vault.UNIT_ETH()), 0);
        assertTrue(dep.router.isStable(0xaf88d065e77c8cC2239327C5EDb3A432268e5831));
        IERC20(address(dep.vault)); // BIETIX es un ERC-20
    }
}

contract FakeSafe {}
