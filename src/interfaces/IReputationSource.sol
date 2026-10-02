// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal reputation interface Leash consumes. Score is 0..100.
interface IReputationSource {
    function trustScore(address counterparty) external view returns (uint256 score);
}
