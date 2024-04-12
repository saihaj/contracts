// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { ISubgraphService } from "./interfaces/ISubgraphService.sol";

contract SubgraphServiceV1Storage {
    // multiplier for how many tokens back collected query fees
    uint256 public stakeToFeesRatio;

    /// @notice The fees cut taken by the subgraph service
    uint256 public feesCut;

    /// @notice Service providers registered in the data service
    mapping(address indexer => ISubgraphService.Indexer details) public indexers;

    // tokens collected so far from the scalar escrow
    mapping(address indexer => mapping(address payer => uint256 tokens)) public tokensCollected;

    mapping(address indexer => uint256 tokens) public provisionTrackerAllocations;
    mapping(address allocationId => ISubgraphService.Allocation allocation) public allocations;
}