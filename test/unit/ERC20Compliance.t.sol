// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Cumplimiento estricto de ERC-20 (EIP-20) y EIP-2612 del token BIETIX: funciones obligatorias,
///         eventos, casos borde y ausencia de comisiones o bloqueos en las transferencias.
contract ERC20ComplianceTest is VaultTestBase {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public override {
        super.setUp();
        _fundAndApprove(alice, 10e18);
        vm.prank(alice);
        vault.mintInKind(10e18, alice);
    }

    function test_metadata() public view {
        assertEq(IERC20Metadata(address(vault)).name(), "Bietix");
        assertEq(IERC20Metadata(address(vault)).symbol(), "BIETIX");
        assertEq(IERC20Metadata(address(vault)).decimals(), 18);
        assertEq(vault.totalSupply(), 10e18);
    }

    function test_transfer_movesExactAmountAndEmits() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit Transfer(alice, bob, 3e18);
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 3e18));
        assertEq(vault.balanceOf(alice), 7e18);
        assertEq(vault.balanceOf(bob), 3e18, "sin comision por transferencia");
        assertEq(vault.totalSupply(), 10e18);
    }

    function test_transfer_zeroValueAndSelfAreAllowed() public {
        vm.startPrank(alice);
        assertTrue(vault.transfer(bob, 0));
        assertTrue(vault.transfer(alice, 1e18));
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), 10e18);
    }

    function test_transfer_revertsAboveBalance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        vault.transfer(alice, 1);
    }

    function test_approve_transferFrom_allowance() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit Approval(alice, bob, 5e18);
        vm.prank(alice);
        assertTrue(vault.approve(bob, 5e18));
        assertEq(vault.allowance(alice, bob), 5e18);

        vm.prank(bob);
        assertTrue(vault.transferFrom(alice, bob, 2e18));
        assertEq(vault.allowance(alice, bob), 3e18);
        assertEq(vault.balanceOf(bob), 2e18);

        // aprobar de nuevo reemplaza el valor (no suma)
        vm.prank(alice);
        vault.approve(bob, 1e18);
        assertEq(vault.allowance(alice, bob), 1e18);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 1e18, 2e18)
        );
        vault.transferFrom(alice, bob, 2e18);
    }

    function test_infiniteApprovalIsNotConsumed() public {
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(bob);
        vault.transferFrom(alice, bob, 1e18);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    /// Ningún rol puede bloquear transferencias: con todo pausado los usuarios siguen transfiriendo.
    function test_transfersWorkWithMintPaused() public {
        vm.prank(guardian);
        vault.pauseMint();
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 1e18));
    }

    function test_permit_eip2612() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        vm.prank(alice);
        vault.transfer(owner, 1e18);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                bob,
                1e18,
                vault.nonces(owner),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash)));
        vault.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(vault.allowance(owner, bob), 1e18);
        assertEq(vault.nonces(owner), 1);
    }

    function test_supportsStandardInterfaceCalls() public view {
        // Las llamadas que hacen DEX y billeteras: todas existen y devuelven valores coherentes.
        IERC20 t = IERC20(address(vault));
        assertEq(t.balanceOf(address(0xdead)), 0);
        assertEq(t.allowance(alice, address(0xdead)), 0);
    }
}
