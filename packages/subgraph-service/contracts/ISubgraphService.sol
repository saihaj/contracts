// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import { ITAPVerifier } from "./ITAPVerifier.sol";

interface ISubgraphService {
    struct Indexer {
        uint256 registeredAt;
        string url;
        string geoHash;
        // tokens being used as slashable stake
        uint256 tokensUsed;
        // tokens collected so far from the scalar escrow
        uint256 tokensCollected;
        bytes32 stakeClaimHead;
        bytes32 stakeClaimTail;
    }

    struct StakeClaim {
        // tokens to be released with this claim
        uint256 tokens;
        // timestamp when the claim can be released
        uint256 releaseAt;
        // next claim in the linked list
        bytes32 nextClaim;
    }

    // register as a provider in the data service
    function register(address serviceProvider, string calldata url, string calldata geohash) external;

    function slash(address serviceProvider, uint256 tokens, uint256 reward) external;

    function redeem(ITAPVerifier.SignedRAV memory rav, address serviceProvider) external returns (uint256 queryFees);

    function release(address serviceProvider, uint256 count) external;
}
