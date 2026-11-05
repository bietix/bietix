// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BietixVault} from "../../src/BietixVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @notice Respuesta a la lista de control de "tax tokens" (impuesto por transferencia, quema automática y
///         acuñación continua). BIETIX no tiene ninguna de esas mecánicas: estas pruebas lo demuestran.
contract TokenMechanicsTest is VaultTestBase {
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public override {
        super.setUp();
        _fundAndApprove(alice, 1_000e18);
        vm.prank(alice);
        vault.mintInKind(1_000e18, alice);
    }

    // ───────────── 1. Transferencia: sin impuesto ─────────────

    /// A transfiere 100 a B: B recibe exactamente 100, nadie más recibe nada y los saldos cuadran.
    function test_transfer100_receiverGets100_noTaxAnywhere() public {
        uint256 supplyBefore = vault.totalSupply();
        uint256 treasuryBefore = vault.balanceOf(treasury);
        vm.prank(alice);
        vault.transfer(bob, 100e18);
        assertEq(vault.balanceOf(bob), 100e18, "B recibe el 100%");
        assertEq(vault.balanceOf(alice), 900e18);
        assertEq(vault.balanceOf(treasury), treasuryBefore, "la tesoreria no cobra en transferencias");
        assertEq(vault.balanceOf(address(vault)), 0, "el contrato no retiene nada");
        assertEq(vault.totalSupply(), supplyBefore, "la transferencia no quema");
        assertEq(vault.balanceOf(alice) + vault.balanceOf(bob), supplyBefore, "los saldos cuadran");
    }

    // ───────────── 2. Quema: solo al canjear, y exacta ─────────────

    /// 10 transferencias seguidas no cambian el supply (no hay quema automática).
    function test_tenTransfers_supplyUnchanged() public {
        uint256 supply = vault.totalSupply();
        for (uint256 i; i < 10; ++i) {
            vm.prank(alice);
            vault.transfer(bob, 10e18);
            vm.prank(bob);
            vault.transfer(alice, 5e18);
        }
        assertEq(vault.totalSupply(), supply);
    }

    /// 10 canjes seguidos: el supply baja exactamente lo canjeado y cada quema emite Transfer a address(0),
    /// que es lo que leen Etherscan y CoinMarketCap.
    function test_tenRedeems_supplyDropsExactly() public {
        uint256 supply = vault.totalSupply();
        uint256 burned;
        for (uint256 i = 1; i <= 10; ++i) {
            uint256 amount = i * 7e18;
            vm.expectEmit(true, true, false, true, address(vault));
            emit Transfer(alice, address(0), amount);
            vm.prank(alice);
            vault.redeemInKind(amount, alice);
            burned += amount;
            assertEq(vault.totalSupply(), supply - burned, "supply exacto despues de cada canje");
        }
        assertEq(vault.balanceOf(alice), supply - burned);
        // y el vault sigue respaldado al 100%
        assertGe(wbtc.balanceOf(address(vault)), vault.totalSupply() * UNIT_BTC / 1e18);
        assertGe(weth.balanceOf(address(vault)), vault.totalSupply() * UNIT_ETH / 1e18);
    }

    // ───────────── 3. Acuñación: nadie puede crear tokens sin colateral ─────────────

    /// No existe una función `mint` de administrador: llamarla revierte para cualquiera, incluido el admin.
    function test_noAdminMintFunctionExists() public {
        bytes memory call = abi.encodeWithSignature("mint(address,uint256)", attacker, 1_000_000e18);
        address[3] memory callers = [attacker, timelock, safe];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok,) = address(vault).call(call);
            assertFalse(ok, "no deberia existir mint");
        }
        assertEq(vault.balanceOf(attacker), 0);
    }

    /// Una billetera común intenta acuñar sin depositar el WBTC/WETH: revierte.
    function test_mintWithoutCollateral_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1_000_000
            )
        );
        vault.mintInKind(100e18, attacker);
        assertEq(vault.balanceOf(attacker), 0);
    }

    /// Ni siquiera el administrador (Timelock) puede acuñar sin colateral ni superar el límite de emisión.
    function test_adminCannotMintWithoutCollateralOrAboveCap() public {
        vm.prank(timelock);
        vm.expectRevert();
        vault.mintInKind(1e18, timelock);

        uint256 room = vault.supplyCap() - vault.totalSupply();
        _fundAndApprove(bob, room);
        vm.prank(bob);
        vm.expectRevert(BietixVault.SupplyCapExceeded.selector);
        vault.mintInKind(room + 1, bob);
    }

    /// Los tokens solo existen si están respaldados: para cualquier monto acuñado, el colateral entra antes.
    function testFuzz_everyMintIsFullyBacked(uint256 shares) public {
        shares = bound(shares, vault.MIN_MINT_SHARES(), 100_000e18);
        uint256 btcBefore = wbtc.balanceOf(address(vault));
        uint256 ethBefore = weth.balanceOf(address(vault));
        _fundAndApprove(bob, shares);
        vm.prank(bob);
        vault.mintInKind(shares, bob);
        assertGe(wbtc.balanceOf(address(vault)) - btcBefore, shares * UNIT_BTC / 1e18);
        assertGe(weth.balanceOf(address(vault)) - ethBefore, shares * UNIT_ETH / 1e18);
    }
}
