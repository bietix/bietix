// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DuoxVault} from "../../src/DuoxVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Ejecuta secuencias aleatorias de operaciones sobre el vault para las pruebas de invariantes.
contract VaultHandler is Test {
    DuoxVault public vault;
    MockERC20 public wbtc;
    MockERC20 public weth;
    address public timelock;
    address public safe;
    address public guardian;

    address[] public actors;

    // contadores para ver qué ejecutó el fuzzer
    uint256 public mints;
    uint256 public redeems;
    uint256 public transfers;
    uint256 public donations;
    /// se marca si alguna acuñación dejó el supply por encima del límite (no debería pasar nunca)
    bool public mintExceededCap;

    constructor(DuoxVault v, MockERC20 b, MockERC20 e, address tl, address sf, address gd) {
        vault = v;
        wbtc = b;
        weth = e;
        timelock = tl;
        safe = sf;
        guardian = gd;
        for (uint256 i; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        if (vault.mintPaused()) return;
        address a = _actor(actorSeed);
        uint256 cap = vault.supplyCap();
        uint256 supply = vault.totalSupply();
        if (cap <= supply || cap - supply < 1e16) return; // el guardián pudo bajar el límite por debajo del supply
        uint256 room = cap - supply;
        shares = bound(shares, 1e16, room < 10_000e18 ? room : 10_000e18);

        (uint256 b, uint256 e, uint256 fb, uint256 fe) = vault.previewMint(shares);
        wbtc.mint(a, b + fb);
        weth.mint(a, e + fe);
        vm.startPrank(a);
        wbtc.approve(address(vault), b + fb);
        weth.approve(address(vault), e + fe);
        vault.mintInKind(shares, a);
        vm.stopPrank();
        mints++;
        if (vault.totalSupply() > vault.supplyCap()) mintExceededCap = true;
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        vault.redeemInKind(shares, a);
        redeems++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        assertTrue(vault.transfer(to, amount));
        transfers++;
    }

    function donate(uint256 btc, uint256 eth) external {
        btc = bound(btc, 0, 1e8);
        eth = bound(eth, 0, 10e18);
        wbtc.mint(address(vault), btc);
        weth.mint(address(vault), eth);
        donations++;
    }

    function pause() external {
        vm.prank(guardian);
        vault.pauseMint();
    }

    function unpause() external {
        vm.prank(safe);
        vault.unpauseMint();
    }

    function setFee(uint256 fee) external {
        fee = bound(fee, 0, 100);
        vm.prank(timelock);
        vault.setMintFee(fee);
    }

    function lowerCap(uint256 newCap) external {
        uint256 cap = vault.supplyCap();
        if (cap == 0) return;
        newCap = bound(newCap, 0, cap - 1);
        vm.prank(guardian);
        vault.decreaseSupplyCap(newCap);
    }

    function raiseCap(uint256 newCap) external {
        uint256 cap = vault.supplyCap();
        if (cap >= 10_000_000e18) return;
        newCap = bound(newCap, cap + 1, 10_000_000e18);
        vm.prank(timelock);
        vault.increaseSupplyCap(newCap);
    }

    /// Un atacante prueba funciones administrativas: todas deben revertir sin cambiar nada.
    function attackerTriesAdmin(uint256 which, uint256 value) external {
        address attacker = address(0xBAD);
        vm.startPrank(attacker);
        uint256 w = which % 5;
        if (w == 0) {
            try vault.setMintFee(bound(value, 0, 100)) {} catch {}
        } else if (w == 1) {
            try vault.increaseSupplyCap(type(uint256).max) {} catch {}
        } else if (w == 2) {
            try vault.setTreasury(attacker) {} catch {}
        } else if (w == 3) {
            try vault.unpauseMint() {} catch {}
        } else {
            try vault.sweep(wbtc) {} catch {}
        }
        vm.stopPrank();
    }
}
