// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Feed de Chainlink falso: permite fijar precio, fecha, decimales y forzar fallas.
contract MockAggregator is AggregatorV3Interface {
    uint8 public override decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    bool public shouldRevert;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setStartedAt(uint256 s) external {
        startedAt = s;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!shouldRevert, "feed caido");
        return (1, answer, startedAt, updatedAt, 1);
    }
}
