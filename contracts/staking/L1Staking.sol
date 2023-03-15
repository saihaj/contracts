// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.7.6;
pragma abicoder v2;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";

import { ITokenGateway } from "../arbitrum/ITokenGateway.sol";
import { Staking } from "./Staking.sol";
import { Stakes } from "./libs/Stakes.sol";
import { IStakingData } from "./IStakingData.sol";
import { IL2Staking } from "../l2/staking/IL2Staking.sol";
import { L1StakingV1Storage } from "./L1StakingStorage.sol";
import { IGraphToken } from "../token/IGraphToken.sol";
import { IL1StakingBase } from "./IL1StakingBase.sol";
import { MathUtils } from "./libs/MathUtils.sol";
import { IL1GraphTokenLockMigrator } from "./IL1GraphTokenLockMigrator.sol";

/**
 * @title L1Staking contract
 * @dev This contract is the L1 variant of the Staking contract. It adds functions
 * to send an indexer's stake to L2, and to send delegation to L2 as well.
 */
contract L1Staking is Staking, L1StakingV1Storage, IL1StakingBase {
    using Stakes for Stakes.Indexer;
    using SafeMath for uint256;

    /**
     * @notice Receive ETH into the Staking contract
     * @dev Only the L1GraphTokenLockMigrator can send ETH, as part of the
     * migration of stake/delegation for vesting lock wallets.
     */
    receive() external payable {
        require(msg.sender == address(l1GraphTokenLockMigrator), "Only migrator can send ETH");
    }

    /**
     * @notice Set the L1GraphTokenLockMigrator contract address
     * @dev This function can only be called by the governor.
     * @param _l1GraphTokenLockMigrator Address of the L1GraphTokenLockMigrator contract
     */
    function setL1GraphTokenLockMigrator(IL1GraphTokenLockMigrator _l1GraphTokenLockMigrator)
        external
        override
        onlyGovernor
    {
        l1GraphTokenLockMigrator = _l1GraphTokenLockMigrator;
        emit L1GraphTokenLockMigratorSet(address(_l1GraphTokenLockMigrator));
    }

    /**
     * @notice Send an indexer's stake to L2.
     * @dev This function can only be called by the indexer (not an operator).
     * It will validate that the remaining stake is sufficient to cover all the allocated
     * stake, so the indexer might have to close some allocations before migrating.
     * It will also check that the indexer's stake is not locked for withdrawal.
     * Since the indexer address might be an L1-only contract, the function takes a beneficiary
     * address that will be the indexer's address in L2.
     * The caller must provide an amount of ETH to use for the L2 retryable ticket, that
     * must be at least `_maxSubmissionCost + _gasPriceBid * _maxGas`.
     * @param _l2Beneficiary Address of the indexer in L2. If the indexer has previously migrated stake, this must match the previously-used value.
     * @param _amount Amount of stake GRT to migrate to L2
     * @param _maxGas Max gas to use for the L2 retryable ticket
     * @param _gasPriceBid Gas price bid for the L2 retryable ticket
     * @param _maxSubmissionCost Max submission cost for the L2 retryable ticket
     */
    function migrateStakeToL2(
        address _l2Beneficiary,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost
    ) external payable override {
        _migrateStakeToL2(
            msg.sender,
            _l2Beneficiary,
            _amount,
            _maxGas,
            _gasPriceBid,
            _maxSubmissionCost,
            msg.value
        );
    }

    /**
     * @notice Send an indexer's stake to L2, from a GraphTokenLockWallet vesting contract.
     * @dev This function can only be called by the indexer (not an operator).
     * It will validate that the remaining stake is sufficient to cover all the allocated
     * stake, so the indexer might have to close some allocations before migrating.
     * It will also check that the indexer's stake is not locked for withdrawal.
     * The L2 beneficiary for the stake will be determined by calling the L1GraphTokenLockMigrator contract,
     * so the caller must have previously migrated tokens through that first
     * (see GIP-0046 for details: https://forum.thegraph.com/t/gip-0046-l2-migration-helpers/4023).
     * The ETH for the L2 gas will be pulled from the L1GraphTokenLockMigrator, so the owner of
     * the GraphTokenLockWallet must have previously deposited at least `_maxSubmissionCost + _gasPriceBid * _maxGas`
     * ETH into the L1GraphTokenLockMigrator contract (using its depositETH function).
     * @param _amount Amount of stake GRT to migrate to L2
     * @param _maxGas Max gas to use for the L2 retryable ticket
     * @param _gasPriceBid Gas price bid for the L2 retryable ticket
     * @param _maxSubmissionCost Max submission cost for the L2 retryable ticket
     */
    function migrateLockedStakeToL2(
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost
    ) external override {
        address l2Beneficiary = l1GraphTokenLockMigrator.migratedWalletAddress(msg.sender);
        require(l2Beneficiary != address(0), "LOCK NOT MIGRATED");
        uint256 balance = address(this).balance;
        uint256 ethAmount = _maxSubmissionCost.add(_maxGas.mul(_gasPriceBid));
        l1GraphTokenLockMigrator.pullETH(msg.sender, ethAmount);
        require(address(this).balance == balance.add(ethAmount), "ETH TRANSFER FAILED");
        _migrateStakeToL2(
            msg.sender,
            l2Beneficiary,
            _amount,
            _maxGas,
            _gasPriceBid,
            _maxSubmissionCost,
            ethAmount
        );
    }

    /**
     * @notice Send a delegator's delegated tokens to L2
     * @dev This function can only be called by the delegator.
     * This function will validate that the indexer has migrated their stake using migrateStakeToL2,
     * and that the delegation is not locked for undelegation.
     * Since the delegator's address might be an L1-only contract, the function takes a beneficiary
     * address that will be the delegator's address in L2.
     * The caller must provide an amount of ETH to use for the L2 retryable ticket, that
     * must be at least `_maxSubmissionCost + _gasPriceBid * _maxGas`.
     * @param _indexer Address of the indexer (in L1, before migrating)
     * @param _l2Beneficiary Address of the delegator in L2
     * @param _maxGas Max gas to use for the L2 retryable ticket
     * @param _gasPriceBid Gas price bid for the L2 retryable ticket
     * @param _maxSubmissionCost Max submission cost for the L2 retryable ticket
     */
    function migrateDelegationToL2(
        address _indexer,
        address _l2Beneficiary,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost
    ) external payable override {
        _migrateDelegationToL2(
            msg.sender,
            _indexer,
            _l2Beneficiary,
            _maxGas,
            _gasPriceBid,
            _maxSubmissionCost,
            msg.value
        );
    }

    /**
     * @notice Send a delegator's delegated tokens to L2, for a GraphTokenLockWallet vesting contract
     * @dev This function can only be called by the delegator.
     * This function will validate that the indexer has migrated their stake using migrateStakeToL2,
     * and that the delegation is not locked for undelegation.
     * The L2 beneficiary for the delegation will be determined by calling the L1GraphTokenLockMigrator contract,
     * so the caller must have previously migrated tokens through that first
     * (see GIP-0046 for details: https://forum.thegraph.com/t/gip-0046-l2-migration-helpers/4023).
     * The ETH for the L2 gas will be pulled from the L1GraphTokenLockMigrator, so the owner of
     * the GraphTokenLockWallet must have previously deposited at least `_maxSubmissionCost + _gasPriceBid * _maxGas`
     * ETH into the L1GraphTokenLockMigrator contract (using its depositETH function).
     * @param _indexer Address of the indexer (in L1, before migrating)
     * @param _maxGas Max gas to use for the L2 retryable ticket
     * @param _gasPriceBid Gas price bid for the L2 retryable ticket
     * @param _maxSubmissionCost Max submission cost for the L2 retryable ticket
     */
    function migrateLockedDelegationToL2(
        address _indexer,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost
    ) external override {
        address l2Beneficiary = l1GraphTokenLockMigrator.migratedWalletAddress(msg.sender);
        require(l2Beneficiary != address(0), "LOCK NOT MIGRATED");
        uint256 balance = address(this).balance;
        uint256 ethAmount = _maxSubmissionCost.add(_maxGas.mul(_gasPriceBid));
        l1GraphTokenLockMigrator.pullETH(msg.sender, ethAmount);
        require(address(this).balance == balance.add(ethAmount), "ETH TRANSFER FAILED");
        _migrateDelegationToL2(
            msg.sender,
            _indexer,
            l2Beneficiary,
            _maxGas,
            _gasPriceBid,
            _maxSubmissionCost,
            ethAmount
        );
    }

    /**
     * @notice Unlock a delegator's delegated tokens, if the indexer has migrated
     * @dev This function can only be called by the delegator.
     * This function will validate that the indexer has migrated their stake using migrateStakeToL2,
     * and that the indexer has no remaining stake in L1.
     * The tokens must previously be locked for undelegation by calling `undelegate()`,
     * and can be withdrawn with `withdrawDelegated()` immediately after calling this.
     * @param _indexer Address of the indexer (in L1, before migrating)
     */
    function unlockDelegationToMigratedIndexer(address _indexer) external override {
        require(
            indexerMigratedToL2[_indexer] != address(0) && __stakes[_indexer].tokensStaked == 0,
            "indexer not migrated"
        );

        Delegation storage delegation = __delegationPools[_indexer].delegators[msg.sender];
        require(delegation.tokensLockedUntil != 0, "! locked");

        // Unlock the delegation
        delegation.tokensLockedUntil = epochManager().currentEpoch();

        // After this, the delegator should be able to withdraw in the current block
        emit StakeDelegatedUnlockedDueToMigration(_indexer, msg.sender);
    }

    /**
     * @dev Implements sending an indexer's stake to L2.
     * This function can only be called by the indexer (not an operator).
     * It will validate that the remaining stake is sufficient to cover all the allocated
     * stake, so the indexer might have to close some allocations before migrating.
     * It will also check that the indexer's stake is not locked for withdrawal.
     * Since the indexer address might be an L1-only contract, the function takes a beneficiary
     * address that will be the indexer's address in L2.
     * @param _l2Beneficiary Address of the indexer in L2. If the indexer has previously migrated stake, this must match the previously-used value.
     * @param _amount Amount of stake GRT to migrate to L2
     * @param _maxGas Max gas to use for the L2 retryable ticket
     * @param _gasPriceBid Gas price bid for the L2 retryable ticket
     * @param _maxSubmissionCost Max submission cost for the L2 retryable ticket
     * @param _ethAmount Amount of ETH to send with the retryable ticket
     */
    function _migrateStakeToL2(
        address _indexer,
        address _l2Beneficiary,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        uint256 _ethAmount
    ) internal {
        Stakes.Indexer storage indexerStake = __stakes[_indexer];
        require(indexerStake.tokensStaked != 0, "tokensStaked == 0");
        // Indexers shouldn't be trying to withdraw tokens before migrating to L2.
        // Allowing this would complicate our accounting so we require that they have no
        // tokens locked for withdrawal.
        require(indexerStake.tokensLocked == 0, "tokensLocked != 0");

        require(_l2Beneficiary != address(0), "l2Beneficiary == 0");
        if (indexerMigratedToL2[_indexer] != address(0)) {
            require(indexerMigratedToL2[_indexer] == _l2Beneficiary, "l2Beneficiary != previous");
        } else {
            indexerMigratedToL2[_indexer] = _l2Beneficiary;
            require(_amount >= __minimumIndexerStake, "!minimumIndexerStake sent");
        }
        // Ensure minimum stake
        indexerStake.tokensStaked = indexerStake.tokensStaked.sub(_amount);
        require(
            indexerStake.tokensStaked == 0 || indexerStake.tokensStaked >= __minimumIndexerStake,
            "!minimumIndexerStake remaining"
        );

        IStakingData.DelegationPool storage delegationPool = __delegationPools[_indexer];

        if (indexerStake.tokensStaked == 0) {
            // require that no allocations are open
            require(indexerStake.tokensAllocated == 0, "allocated");
        } else {
            // require that the indexer has enough stake to cover all allocations
            uint256 tokensDelegatedCap = indexerStake.tokensStaked.mul(uint256(__delegationRatio));
            uint256 tokensDelegatedCapacity = MathUtils.min(
                delegationPool.tokens,
                tokensDelegatedCap
            );
            require(
                indexerStake.tokensUsed() <= indexerStake.tokensStaked.add(tokensDelegatedCapacity),
                "! allocation capacity"
            );
        }

        IL2Staking.ReceiveIndexerStakeData memory functionData;
        functionData.indexer = _l2Beneficiary;

        bytes memory extraData = abi.encode(
            uint8(IL2Staking.L1MessageCodes.RECEIVE_INDEXER_STAKE_CODE),
            abi.encode(functionData)
        );

        _sendTokensAndMessageToL2Staking(
            _amount,
            _maxGas,
            _gasPriceBid,
            _maxSubmissionCost,
            _ethAmount,
            extraData
        );

        emit IndexerMigratedToL2(_indexer, _l2Beneficiary, _amount);
    }

    /**
     * @dev Implements sending a delegator's delegated tokens to L2.
     * This function can only be called by the delegator.
     * This function will validate that the indexer has migrated their stake using migrateStakeToL2,
     * and that the delegation is not locked for undelegation.
     * Since the delegator's address might be an L1-only contract, the function takes a beneficiary
     * address that will be the delegator's address in L2.
     * @param _indexer Address of the indexer (in L1, before migrating)
     * @param _l2Beneficiary Address of the delegator in L2
     * @param _maxGas Max gas to use for the L2 retryable ticket
     * @param _gasPriceBid Gas price bid for the L2 retryable ticket
     * @param _maxSubmissionCost Max submission cost for the L2 retryable ticket
     * @param _ethAmount Amount of ETH to send with the retryable ticket
     */
    function _migrateDelegationToL2(
        address _delegator,
        address _indexer,
        address _l2Beneficiary,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        uint256 _ethAmount
    ) internal {
        require(_l2Beneficiary != address(0), "l2Beneficiary == 0");
        require(indexerMigratedToL2[_indexer] != address(0), "indexer not migrated");

        // Get the delegation pool of the indexer
        DelegationPool storage pool = __delegationPools[_indexer];
        Delegation storage delegation = pool.delegators[_delegator];

        // Check that the delegation is not locked for undelegation
        require(delegation.tokensLockedUntil == 0, "tokensLocked != 0");
        require(delegation.shares != 0, "delegation == 0");
        // Calculate tokens to get in exchange for the shares
        uint256 tokensToSend = delegation.shares.mul(pool.tokens).div(pool.shares);

        // Update the delegation pool
        pool.tokens = pool.tokens.sub(tokensToSend);
        pool.shares = pool.shares.sub(delegation.shares);

        // Update the delegation
        delegation.shares = 0;
        bytes memory extraData;
        {
            IL2Staking.ReceiveDelegationData memory functionData;
            functionData.indexer = indexerMigratedToL2[_indexer];
            functionData.delegator = _l2Beneficiary;
            extraData = abi.encode(
                uint8(IL2Staking.L1MessageCodes.RECEIVE_DELEGATION_CODE),
                abi.encode(functionData)
            );
        }

        _sendTokensAndMessageToL2Staking(
            tokensToSend,
            _maxGas,
            _gasPriceBid,
            _maxSubmissionCost,
            _ethAmount,
            extraData
        );
        emit DelegationMigratedToL2(
            _delegator,
            _l2Beneficiary,
            _indexer,
            indexerMigratedToL2[_indexer],
            tokensToSend
        );
    }

    /**
     * @dev Sends a message to the L2Staking with some extra data,
     * also sending some tokens, using the L1GraphTokenGateway.
     * @param _tokens Amount of tokens to send to L2
     * @param _maxGas Max gas to use for the L2 retryable ticket
     * @param _gasPriceBid Gas price bid for the L2 retryable ticket
     * @param _maxSubmissionCost Max submission cost for the L2 retryable ticket
     * @param _value Amount of ETH to send with the message
     * @param _extraData Extra data for the callhook on L2Staking
     */
    function _sendTokensAndMessageToL2Staking(
        uint256 _tokens,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        uint256 _value,
        bytes memory _extraData
    ) internal {
        IGraphToken grt = graphToken();
        ITokenGateway gateway = graphTokenGateway();
        grt.approve(address(gateway), _tokens);
        gateway.outboundTransfer{ value: _value }(
            address(grt),
            counterpartStakingAddress,
            _tokens,
            _maxGas,
            _gasPriceBid,
            abi.encode(_maxSubmissionCost, _extraData)
        );
    }
}