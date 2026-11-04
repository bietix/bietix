// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DuoxVault} from "../../src/DuoxVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Despliegue común para todas las pruebas del vault.
abstract contract VaultTestBase is Test {
    // Definición del índice usada en las pruebas: 1 DUOX = 0,0001 BTC + 0,003 ETH
    uint256 internal constant UNIT_BTC = 10_000; // sats (8 decimales)
    uint256 internal constant UNIT_ETH = 3e15; // wei (18 decimales)
    uint256 internal constant FEE_BPS = 5; // 0,05%
    uint256 internal constant CAP = 1_000_000e18;
    uint48 internal constant ADMIN_DELAY = 2 days;

    address internal timelock = makeAddr("timelock");
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    MockERC20 internal wbtc;
    MockERC20 internal weth;
    DuoxVault internal vault;

    function setUp() public virtual {
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vault = new DuoxVault("DUOX Index", "DUOX", _config(IERC20(address(wbtc)), IERC20(address(weth))));
    }

    function _config(IERC20 b, IERC20 e) internal view returns (DuoxVault.Config memory c) {
        c = DuoxVault.Config({
            assetBtc: b,
            assetEth: e,
            unitBtc: UNIT_BTC,
            unitEth: UNIT_ETH,
            admin: timelock,
            adminTransferDelay: ADMIN_DELAY,
            safe: safe,
            guardian: guardian,
            treasury: treasury,
            mintFeeBps: FEE_BPS,
            supplyCap: CAP
        });
    }

    /// @dev Da al usuario los activos justos para acuñar `shares` (incluida la comisión) y aprueba al vault.
    function _fundAndApprove(address user, uint256 shares) internal {
        (uint256 b, uint256 e, uint256 fb, uint256 fe) = vault.previewMint(shares);
        wbtc.mint(user, b + fb);
        weth.mint(user, e + fe);
        vm.startPrank(user);
        wbtc.approve(address(vault), b + fb);
        weth.approve(address(vault), e + fe);
        vm.stopPrank();
    }

    function _mint(address user, uint256 shares) internal {
        _fundAndApprove(user, shares);
        vm.prank(user);
        vault.mintInKind(shares, user);
    }
}
