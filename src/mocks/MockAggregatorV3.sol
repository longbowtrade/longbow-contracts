// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Settable Chainlink AggregatorV3 stand-in (8 decimals by default).
///         Also doubles as a sequencer uptime feed (answer 0 = up, 1 = down).
contract MockAggregatorV3 {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public roundId;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
        roundId = 1;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId += 1;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setStartedAt(uint256 _startedAt) external {
        startedAt = _startedAt;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}
