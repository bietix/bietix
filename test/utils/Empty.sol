// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleGuard} from "../../src/OracleGuard.sol";

/// @dev Listas vacías para desplegar sin configuración inicial (las pruebas configuran después).
function noFeeds() pure returns (OracleGuard.FeedInit[] memory) {
    return new OracleGuard.FeedInit[](0);
}

function noStables() pure returns (OracleGuard.StableInit[] memory) {
    return new OracleGuard.StableInit[](0);
}

function noAddresses() pure returns (address[] memory) {
    return new address[](0);
}
