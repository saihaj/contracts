// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.24;

import { GraphUpgradeable } from "@graphprotocol/contracts/contracts/upgrades/GraphUpgradeable.sol";

import { IHorizonStaking } from "./IHorizonStaking.sol";
import { TokenUtils } from "./utils/TokenUtils.sol";
import { MathUtils } from "./utils/MathUtils.sol";
import { Managed } from "./Managed.sol";
import { IGraphToken } from "./IGraphToken.sol";
import { HorizonStakingV1Storage } from "./HorizonStakingStorage.sol";

contract HorizonStaking is HorizonStakingV1Storage, IHorizonStaking, GraphUpgradeable {
    /// Maximum value that can be set as the maxVerifierCut in a provision.
    /// It is equivalent to 50% in parts-per-million, to protect delegators from
    /// service providers using a malicious verifier.
    uint32 public constant MAX_MAX_VERIFIER_CUT = 500000; // 50%

    /// Minimum size of a provision
    uint256 public constant MIN_PROVISION_SIZE = 1e18;

    /// Maximum number of simultaneous stake thaw requests or undelegations
    uint256 public constant MAX_THAW_REQUESTS = 100;

    uint256 public constant FIXED_POINT_PRECISION = 1e18;

    /// Minimum delegation size
    uint256 public constant MINIMUM_DELEGATION = 1e18;

    address public immutable L2_STAKING_BACKWARDS_COMPATIBILITY;
    address public immutable SUBGRAPH_DATA_SERVICE_ADDRESS;

    error HorizonStakingInvalidVerifier(address verifier);
    error HorizonStakingVerifierAlreadyAllowed(address verifier);
    error HorizonStakingVerifierNotAllowed(address verifier);
    error HorizonStakingInvalidZeroTokens();
    error HorizonStakingInvalidProvision(address serviceProvider, address verifier);
    error HorizonStakingNotAuthorized(address caller, address serviceProvider, address verifier);
    error HorizonStakingNotGlobalAuthorized(address caller, address serviceProvider);
    error HorizonStakingInsufficientCapacity();

    constructor(
        address _controller,
        address _l2StakingBackwardsCompatibility,
        address _subgraphDataServiceAddress
     ) Managed(_controller) {
        L2_STAKING_BACKWARDS_COMPATIBILITY = _l2StakingBackwardsCompatibility;
        SUBGRAPH_DATA_SERVICE_ADDRESS = _subgraphDataServiceAddress;
     }

    /**
     * @notice Delegates the current call to the StakingExtension implementation.
     * @dev This function does not return to its internal call site, it will return directly to the
     * external caller.
     */
    // solhint-disable-next-line payable-fallback, no-complex-fallback
    fallback() external {
        require(_implementation() != address(0), "only through proxy");
        address extensionImpl = L2_STAKING_BACKWARDS_COMPATIBILITY;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // (a) get free memory pointer
            let ptr := mload(0x40)

            // (1) copy incoming call data
            calldatacopy(ptr, 0, calldatasize())

            // (2) forward call to logic contract
            let result := delegatecall(gas(), extensionImpl, ptr, calldatasize(), 0, 0)
            let size := returndatasize()

            // (3) retrieve return data
            returndatacopy(ptr, 0, size)

            // (4) forward return data back to caller
            switch result
            case 0 {
                revert(ptr, size)
            }
            default {
                return(ptr, size)
            }
        }
    }

    /**
     * @notice Allow verifier for stake provisions.
     * After calling this, and a timelock period, the service provider will
     * be allowed to provision stake that is slashable by the verifier.
     * @param _verifier The address of the contract that can slash the provision
     */
    function allowVerifier(address _verifier) external override {
        if (_verifier == address(0)) {
            revert HorizonStakingInvalidVerifier(_verifier);
        }
        if (verifierAllowlist[msg.sender][_verifier]) {
            revert HorizonStakingVerifierAlreadyAllowed(_verifier);
        }
        verifierAllowlist[msg.sender][_verifier] = true;
        emit VerifierAllowed(msg.sender, _verifier);
    }

    /**
     * @notice Deny a verifier for stake provisions.
     * After calling this, the service provider will immediately
     * be unable to provision any stake to the verifier.
     * Any existing provisions will be unaffected.
     * @param _verifier The address of the contract that can slash the provision
     */
    function denyVerifier(address _verifier) external override {
        if (!verifierAllowlist[msg.sender][_verifier]) {
            revert HorizonStakingVerifierNotAllowed(_verifier);
        }
        verifierAllowlist[msg.sender][_verifier] = false;
        emit VerifierDenied(msg.sender, _verifier);
    }

    /**
     * @notice Deposit tokens on the caller's stake.
     * @param _tokens Amount of tokens to stake
     */
    function stake(uint256 _tokens) external override {
        stakeTo(msg.sender, _tokens);
    }

    /**
     * @notice Deposit tokens on the service provider stake, on behalf of the service provider.
     * @param _serviceProvider Address of the indexer
     * @param _tokens Amount of tokens to stake
     */
    function stakeTo(address _serviceProvider, uint256 _tokens) public override notPartialPaused {
        if (_tokens == 0) {
            revert HorizonStakingInvalidZeroTokens();
        }

        // Transfer tokens to stake from caller to this contract
        TokenUtils.pullTokens(_graphToken(), msg.sender, _tokens);

        // Stake the transferred tokens
        _stake(_serviceProvider, _tokens);
    }

    // can be called by anyone if the indexer has provisioned stake to this verifier
    function stakeToProvision(
        address _serviceProvider,
        address _verifier,
        uint256 _tokens
    ) external override notPartialPaused {
        Provision storage prov = provisions[_serviceProvider][_verifier];
        if (prov.tokens == 0) {
            revert HorizonStakingInvalidProvision(_serviceProvider, _verifier);
        }
        stakeTo(_serviceProvider, _tokens);
        _addToProvision(_serviceProvider, _verifier, _tokens);
    }

    // create a provision
    function provision(
        address _serviceProvider,
        address _verifier,
        uint256 _tokens,
        uint32 _maxVerifierCut,
        uint64 _thawingPeriod
    ) external override notPartialPaused {
        if (!isAuthorized(msg.sender, _serviceProvider, _verifier)) {
            revert HorizonStakingNotAuthorized(msg.sender, _serviceProvider, _verifier);
        }
        if (getIdleStake(_serviceProvider) < _tokens) {
            revert HorizonStakingInsufficientCapacity();
        }
        if (!verifierAllowlist[_serviceProvider][_verifier]) {
            revert HorizonStakingVerifierNotAllowed(_verifier);
        }

        _createProvision(_serviceProvider, _tokens, _verifier, _maxVerifierCut, _thawingPeriod);
    }

    // add more tokens from idle stake to an existing provision
    function addToProvision(
        address _serviceProvider,
        address _verifier,
        uint256 _tokens
    ) external override notPartialPaused {
        require(isAuthorized(msg.sender, _serviceProvider, _verifier), "!auth");
        _addToProvision(_serviceProvider, _verifier, _tokens);
    }

    // initiate a thawing to remove tokens from a provision
    function thaw(
        address _serviceProvider,
        address _verifier,
        uint256 _tokens
    ) external override notPartialPaused returns (bytes32) {
        require(isAuthorized(msg.sender, _serviceProvider, _verifier), "!auth");
        require(_tokens > 0, "!tokens");
        Provision storage prov = provisions[_serviceProvider][_verifier];
        ServiceProviderInternal storage serviceProvider = serviceProviders[_serviceProvider];
        bytes32 thawRequestId = keccak256(
            abi.encodePacked(_serviceProvider, _verifier, serviceProvider.nextThawRequestNonce)
        );
        serviceProvider.nextThawRequestNonce += 1;
        ThawRequest storage thawRequest = thawRequests[thawRequestId];

        require(getProviderTokensAvailable(_serviceProvider, _verifier) >= _tokens, "insufficient tokens available");
        prov.tokensThawing = prov.tokensThawing + _tokens;

        thawRequest.shares = (prov.sharesThawing * _tokens) / prov.tokensThawing;
        thawRequest.thawingUntil = uint64(block.timestamp + uint256(prov.thawingPeriod));
        prov.sharesThawing = prov.sharesThawing + thawRequest.shares;

        require(prov.nThawRequests < MAX_THAW_REQUESTS, "max thaw requests");
        if (prov.nThawRequests == 0) {
            prov.firstThawRequestId = thawRequestId;
        } else {
            thawRequests[prov.lastThawRequestId].next = thawRequestId;
        }
        prov.lastThawRequestId = thawRequestId;
        prov.nThawRequests += 1;

        emit ProvisionThawInitiated(_serviceProvider, _verifier, _tokens, thawRequest.thawingUntil, thawRequestId);

        return thawRequestId;
    }

    /**
     * @notice Get the amount of service provider's tokens in a provision that have finished thawing
     * @param _serviceProvider The service provider address
     * @param _verifier The verifier address for which the tokens are provisioned
     */
    function getThawedTokens(address _serviceProvider, address _verifier) external view returns (uint256) {
        Provision storage prov = provisions[_serviceProvider][_verifier];
        if (prov.nThawRequests == 0) {
            return 0;
        }
        bytes32 thawRequestId = prov.firstThawRequestId;
        uint256 tokens = 0;
        while (thawRequestId != bytes32(0)) {
            ThawRequest storage thawRequest = thawRequests[thawRequestId];
            if (thawRequest.thawingUntil <= block.timestamp) {
                tokens += (thawRequest.shares * prov.tokensThawing) / prov.sharesThawing;
            } else {
                break;
            }
            thawRequestId = thawRequest.next;
        }
        return tokens;
    }

    // moves thawed stake from a provision back into the provider's available stake
    function deprovision(
        address _serviceProvider,
        address _verifier,
        uint256 _tokens
    ) external override notPartialPaused {
        require(isAuthorized(msg.sender, _serviceProvider, _verifier), "!auth");
        require(_tokens > 0, "!tokens");
        ServiceProviderInternal storage serviceProvider = serviceProviders[_serviceProvider];
        _fulfillThawRequests(_serviceProvider, _verifier, _tokens);
        serviceProvider.tokensProvisioned = serviceProvider.tokensProvisioned - _tokens;
    }

    // moves thawed stake from one provision into another provision
    function reprovision(
        address _serviceProvider,
        address _oldVerifier,
        address _newVerifier,
        uint256 _tokens
    ) external override notPartialPaused {
        require(isAuthorized(msg.sender, _serviceProvider, _oldVerifier), "!auth");
        require(isAuthorized(msg.sender, _serviceProvider, _newVerifier), "!auth");
        require(_tokens > 0, "!tokens");

        _fulfillThawRequests(_serviceProvider, _oldVerifier, _tokens);
        _addToProvision(_serviceProvider, _newVerifier, _tokens);
    }

    // moves idle stake back to the owner's account - stake is removed from the protocol
    // global operators are allowed to call this but stake is always sent to the service provider's address
    function unstake(address _serviceProvider, uint256 _tokens) external override notPaused {
        require(isGlobalAuthorized(msg.sender, _serviceProvider), "!auth");
        require(_tokens > 0, "!tokens");
        require(getIdleStake(_serviceProvider) >= _tokens, "insufficient idle stake");

        ServiceProviderInternal storage sp = serviceProviders[_serviceProvider];
        uint256 stakedTokens = sp.tokensStaked;
        // Check that the indexer's stake minus
        // TODO this is only needed until legacy allocations are closed,
        // so we should remove it after the transition period
        require((stakedTokens - _tokens) >= sp.__DEPRECATED_tokensAllocated, "!stake-avail");

        // This is also only during the transition period: we need
        // to ensure tokens stay locked after closing legacy allocations.
        // After sufficient time (56 days?) we should remove the closeAllocation function
        // and set the thawing period to 0.
        uint256 lockingPeriod = __DEPRECATED_thawingPeriod;
        if (lockingPeriod == 0) {
            sp.tokensStaked = stakedTokens - _tokens;
            TokenUtils.pushTokens(_graphToken(), _serviceProvider, _tokens);
            emit StakeWithdrawn(_serviceProvider, _tokens);
        } else {
            // Before locking more tokens, withdraw any unlocked ones if possible
            if (sp.__DEPRECATED_tokensLockedUntil != 0 && block.number >= sp.__DEPRECATED_tokensLockedUntil) {
                _withdraw(_serviceProvider);
            }
            // TODO remove after the transition period
            // Take into account period averaging for multiple unstake requests
            if (sp.__DEPRECATED_tokensLocked > 0) {
                lockingPeriod = MathUtils.weightedAverageRoundingUp(
                    MathUtils.diffOrZero(sp.__DEPRECATED_tokensLockedUntil, block.number), // Remaining thawing period
                    sp.__DEPRECATED_tokensLocked, // Weighted by remaining unstaked tokens
                    lockingPeriod, // Thawing period
                    _tokens // Weighted by new tokens to unstake
                );
            }

            // Update balances
            sp.__DEPRECATED_tokensLocked = sp.__DEPRECATED_tokensLocked + _tokens;
            sp.__DEPRECATED_tokensLockedUntil = block.number + lockingPeriod;
            emit StakeLocked(_serviceProvider, sp.__DEPRECATED_tokensLocked, sp.__DEPRECATED_tokensLockedUntil);
        }
    }

    // slash a service provider
    // (called by a verifier)
    // if delegation slashing is disabled and it would've happened,
    // this is skipped rather than reverting
    function slash(
        address _serviceProvider,
        uint256 _tokens,
        uint256 _verifierCutAmount,
        address _verifierCutDestination
    ) external override notPartialPaused {
        address verifier = msg.sender;
        Provision storage prov = provisions[_serviceProvider][verifier];
        require(prov.tokens >= _tokens, "insufficient tokens in provision");

        uint256 tokensToSlash = _tokens;

        uint256 providerTokensSlashed = MathUtils.min(prov.tokens, tokensToSlash);
        require((prov.tokens * prov.maxVerifierCut) / 1e6 >= _verifierCutAmount, "verifier cut too high");
        if (_verifierCutAmount > 0) {
            TokenUtils.pushTokens(_graphToken(), _verifierCutDestination, _verifierCutAmount);
            emit VerifierCutSent(_serviceProvider, verifier, _verifierCutDestination, _verifierCutAmount);
        }
        if (providerTokensSlashed > 0) {
            TokenUtils.burnTokens(_graphToken(), providerTokensSlashed);
            uint256 provisionFractionSlashed = (providerTokensSlashed * FIXED_POINT_PRECISION) / prov.tokens;
            // TODO check for rounding issues
            prov.tokensThawing =
                (prov.tokensThawing * (FIXED_POINT_PRECISION - provisionFractionSlashed)) /
                (FIXED_POINT_PRECISION);
            prov.tokens = prov.tokens - providerTokensSlashed;
            serviceProviders[_serviceProvider].tokensProvisioned =
                serviceProviders[_serviceProvider].tokensProvisioned -
                providerTokensSlashed;
            serviceProviders[_serviceProvider].tokensStaked =
                serviceProviders[_serviceProvider].tokensStaked -
                providerTokensSlashed;
            emit ProvisionSlashed(_serviceProvider, verifier, providerTokensSlashed);
        }

        tokensToSlash = tokensToSlash - providerTokensSlashed;
        if (tokensToSlash > 0) {
            DelegationPool storage pool;
            if (verifier == SUBGRAPH_DATA_SERVICE_ADDRESS) {
                pool = legacyDelegationPools[_serviceProvider];
            } else {
                pool = delegationPools[_serviceProvider][verifier];
            }
            if (delegationSlashingEnabled) {
                require(pool.tokens >= tokensToSlash, "insufficient delegated tokens");
                TokenUtils.burnTokens(_graphToken(), tokensToSlash);
                uint256 delegationFractionSlashed = (tokensToSlash * FIXED_POINT_PRECISION) / pool.tokens;
                pool.tokens = pool.tokens - tokensToSlash;
                pool.tokensThawing =
                    (pool.tokensThawing * (FIXED_POINT_PRECISION - delegationFractionSlashed)) /
                    FIXED_POINT_PRECISION;
                emit DelegationSlashed(_serviceProvider, verifier, tokensToSlash);
            } else {
                emit DelegationSlashingSkipped(_serviceProvider, verifier, tokensToSlash);
            }
        }
    }

    /**
     * @notice Check if an operator is authorized for the caller on a specific verifier / data service.
     * @param _operator The address to check for auth
     * @param _serviceProvider The service provider on behalf of whom they're claiming to act
     * @param _verifier The verifier / data service on which they're claiming to act
     */
    function isAuthorized(
        address _operator,
        address _serviceProvider,
        address _verifier
    ) private view returns (bool) {
        if (_operator == _serviceProvider) {
            return true;
        }
        if (_verifier == SUBGRAPH_DATA_SERVICE_ADDRESS) {
            return legacyOperatorAuth[_serviceProvider][_operator] || globalOperatorAuth[_serviceProvider][_operator];
        } else {
            return
                operatorAuth[_serviceProvider][_verifier][_operator] || globalOperatorAuth[_serviceProvider][_operator];
        }
    }

    // staked tokens that are currently not provisioned, aka idle stake
    // `getStake(serviceProvider) - ServiceProvider.tokensProvisioned`
    function getIdleStake(address serviceProvider) public view override returns (uint256 tokens) {
        return
            serviceProviders[serviceProvider].tokensStaked -
            serviceProviders[serviceProvider].tokensProvisioned -
            serviceProviders[serviceProvider].__DEPRECATED_tokensLocked;
    }

    // provisioned tokens from the service provider that are not being thawed
    // `Provision.tokens - Provision.tokensThawing`
    function getProviderTokensAvailable(
        address _serviceProvider,
        address _verifier
    ) public view returns (uint256) {
        return provisions[_serviceProvider][_verifier].tokens - provisions[_serviceProvider][_verifier].tokensThawing;
    }

    /**
     * @notice Authorize or unauthorize an address to be an operator for the caller on a data service.
     * @param _operator Address to authorize or unauthorize
     * @param _verifier The verifier / data service on which they'll be allowed to operate
     * @param _allowed Whether the operator is authorized or not
     */
    function setOperator(address _operator, address _verifier, bool _allowed) external override {
        require(_operator != msg.sender, "operator == sender");
        if (_verifier == SUBGRAPH_DATA_SERVICE_ADDRESS) {
            legacyOperatorAuth[msg.sender][_operator] = _allowed;
        } else {
            operatorAuth[msg.sender][_verifier][_operator] = _allowed;
        }
        emit OperatorSet(msg.sender, _operator, _verifier, _allowed);
    }

    /**
     * @notice Authorize or unauthorize an address to be an operator for the caller on all data services.
     * @param _operator Address to authorize or unauthorize
     * @param _allowed Whether the operator is authorized or not
     */
    function setGlobalOperator(address _operator, bool _allowed) external override {
        require(_operator != msg.sender, "operator == sender");
        globalOperatorAuth[msg.sender][_operator] = _allowed;
        emit GlobalOperatorSet(msg.sender, _operator, _allowed);
    }

    /**
     * @notice Check if an operator is authorized for the caller on all their allowlisted verifiers and global stake.
     * @param _operator The address to check for auth
     * @param _serviceProvider The service provider on behalf of whom they're claiming to act
     */
    function isGlobalAuthorized(address _operator, address _serviceProvider) public view override returns (bool) {
        return _operator == _serviceProvider || globalOperatorAuth[_serviceProvider][_operator];
    }

    /**
     * @notice Withdraw indexer tokens once the thawing period has passed.
     * @dev This is only needed during the transition period while we still have
     * a global lock. After that, unstake() will also withdraw.
     */
    function withdrawLocked(address _serviceProvider) external override notPaused {
        require(isGlobalAuthorized(msg.sender, _serviceProvider), "!auth");
        _withdraw(_serviceProvider);
    }

    function delegate(address _serviceProvider, address _verifier, uint256 _tokens) public override notPartialPaused {
        // Transfer tokens to stake from caller to this contract
        TokenUtils.pullTokens(_graphToken(), msg.sender, _tokens);
        _delegate(_serviceProvider, _verifier, _tokens);
    }

    // For backwards compatibility, delegates to the subgraph data service
    function delegate(address _serviceProvider, uint256 _tokens) external {
        delegate(_serviceProvider, SUBGRAPH_DATA_SERVICE_ADDRESS, _tokens);
    }

    // For backwards compatibility, undelegates from the subgraph data service
    function undelegate(address _serviceProvider, uint256 _shares) external {
        undelegate(_serviceProvider, SUBGRAPH_DATA_SERVICE_ADDRESS, _shares);
    }

    // For backwards compatibility, withdraws delegated tokens from the subgraph data service
    function withdrawDelegated(address _serviceProvider, address _newServiceProvider) external {
        withdrawDelegated(_serviceProvider, SUBGRAPH_DATA_SERVICE_ADDRESS, _newServiceProvider);
    }

    function _delegate(address _serviceProvider, address _verifier, uint256 _tokens) internal {
        require(_tokens > 0, "!tokens");
        require(provisions[_serviceProvider][_verifier].tokens >= 0, "!provision");

        // Only allow delegations over a minimum, to prevent rounding attacks
        require(_tokens >= MINIMUM_DELEGATION, "!minimum-delegation");
        DelegationPool storage pool;
        if (_verifier == SUBGRAPH_DATA_SERVICE_ADDRESS) {
            pool = legacyDelegationPools[_serviceProvider];
        } else {
            pool = delegationPools[_serviceProvider][_verifier];
        }
        Delegation storage delegation = pool.delegators[msg.sender];

        // Calculate shares to issue
        uint256 shares = (pool.tokens == 0) ? _tokens : ((_tokens * pool.shares) / (pool.tokens - pool.tokensThawing));
        require(shares > 0, "!shares");

        pool.tokens = pool.tokens + _tokens;
        pool.shares = pool.shares + shares;

        delegation.shares = delegation.shares + shares;

        emit TokensDelegated(_serviceProvider, _verifier, msg.sender, _tokens);
    }

    // undelegete tokens from a service provider
    // the shares are burned and replaced with shares in the thawing pool
    function undelegate(address _serviceProvider, address _verifier, uint256 _shares) public override notPartialPaused {
        require(_shares > 0, "!shares");
        DelegationPool storage pool;
        if (_verifier == SUBGRAPH_DATA_SERVICE_ADDRESS) {
            pool = legacyDelegationPools[_serviceProvider];
        } else {
            pool = delegationPools[_serviceProvider][_verifier];
        }
        Delegation storage delegation = pool.delegators[msg.sender];
        require(delegation.shares >= _shares, "!shares-avail");

        uint256 tokens = (_shares * (pool.tokens - pool.tokensThawing)) / pool.shares;

        uint256 thawingShares = pool.tokensThawing == 0 ? tokens : ((tokens * pool.sharesThawing) / pool.tokensThawing);
        pool.tokensThawing = pool.tokensThawing + tokens;

        pool.shares = pool.shares - _shares;
        delegation.shares = delegation.shares - _shares;

        bytes32 thawRequestId = keccak256(
            abi.encodePacked(_serviceProvider, _verifier, msg.sender, delegation.nextThawRequestNonce)
        );
        delegation.nextThawRequestNonce += 1;
        ThawRequest storage thawRequest = thawRequests[thawRequestId];
        thawRequest.shares = thawingShares;
        thawRequest.thawingUntil = uint64(
            block.timestamp + uint256(provisions[_serviceProvider][_verifier].thawingPeriod)
        );
        require(delegation.nThawRequests < MAX_THAW_REQUESTS, "max thaw requests");
        if (delegation.nThawRequests == 0) {
            delegation.firstThawRequestId = thawRequestId;
        } else {
            thawRequests[delegation.lastThawRequestId].next = thawRequestId;
        }
        delegation.lastThawRequestId = thawRequestId;
        unchecked {
            delegation.nThawRequests += 1;
        }
        emit TokensUndelegated(_serviceProvider, _verifier, msg.sender, tokens);
    }

    function withdrawDelegated(
        address _serviceProvider,
        address _verifier,
        address _newServiceProvider
    ) public override notPartialPaused {
        DelegationPool storage pool;
        if (_verifier == SUBGRAPH_DATA_SERVICE_ADDRESS) {
            pool = legacyDelegationPools[_serviceProvider];
        } else {
            pool = delegationPools[_serviceProvider][_verifier];
        }
        Delegation storage delegation = pool.delegators[msg.sender];
        uint256 thawedTokens = 0;

        uint256 sharesThawing = pool.sharesThawing;
        uint256 tokensThawing = pool.tokensThawing;
        require(delegation.nThawRequests > 0, "no thaw requests");
        bytes32 thawRequestId = delegation.firstThawRequestId;
        while (thawRequestId != bytes32(0)) {
            ThawRequest storage thawRequest = thawRequests[thawRequestId];
            if (thawRequest.thawingUntil <= block.timestamp) {
                uint256 tokens = (thawRequest.shares * tokensThawing) / sharesThawing;
                tokensThawing = tokensThawing - tokens;
                sharesThawing = sharesThawing - thawRequest.shares;
                thawedTokens = thawedTokens + tokens;
                delete thawRequests[thawRequestId];
                delegation.firstThawRequestId = thawRequest.next;
                delegation.nThawRequests -= 1;
                if (delegation.nThawRequests == 0) {
                    delegation.lastThawRequestId = bytes32(0);
                }
            } else {
                break;
            }
            thawRequestId = thawRequest.next;
        }

        pool.tokens = pool.tokens - thawedTokens;
        pool.sharesThawing = sharesThawing;
        pool.tokensThawing = tokensThawing;

        if (_newServiceProvider != address(0)) {
            _delegate(_newServiceProvider, _verifier, thawedTokens);
        } else {
            TokenUtils.pushTokens(_graphToken(), msg.sender, thawedTokens);
        }
        emit DelegatedTokensWithdrawn(_serviceProvider, _verifier, msg.sender, thawedTokens);
    }

    function setDelegationSlashingEnabled(bool _enabled) external override onlyGovernor {
        delegationSlashingEnabled = _enabled;
        emit DelegationSlashingEnabled(_enabled);
    }

    // To be called at the end of the transition period, to set the deprecated thawing period to 0
    function clearThawingPeriod() external onlyGovernor {
        __DEPRECATED_thawingPeriod = 0;
        emit ParameterUpdated("thawingPeriod");
    }

    /**
     * @dev Withdraw indexer tokens once the thawing period has passed.
     * @param _indexer Address of indexer to withdraw funds from
     */
    function _withdraw(address _indexer) private {
        // Get tokens available for withdraw and update balance
        ServiceProviderInternal storage sp = serviceProviders[_indexer];
        uint256 tokensToWithdraw = sp.__DEPRECATED_tokensLocked;
        require(tokensToWithdraw > 0, "!tokens");
        require(block.number >= sp.__DEPRECATED_tokensLockedUntil, "locked");

        // Reset locked tokens
        sp.__DEPRECATED_tokensLocked = 0;
        sp.__DEPRECATED_tokensLockedUntil = 0;

        sp.tokensStaked = sp.tokensStaked - tokensToWithdraw;

        // Return tokens to the indexer
        TokenUtils.pushTokens(_graphToken(), _indexer, tokensToWithdraw);

        emit StakeWithdrawn(_indexer, tokensToWithdraw);
    }

    /**
     * @dev Creates a provision
     */
    function _createProvision(
        address _serviceProvider,
        uint256 _tokens,
        address _verifier,
        uint32 _maxVerifierCut,
        uint64 _thawingPeriod
    ) internal {
        require(_tokens >= MIN_PROVISION_SIZE, "!tokens");
        require(_maxVerifierCut <= MAX_MAX_VERIFIER_CUT, "maxVerifierCut too high");
        require(_thawingPeriod <= maxThawingPeriod, "thawingPeriod too high");
        provisions[_serviceProvider][_verifier] = Provision({
            tokens: _tokens,
            tokensThawing: 0,
            sharesThawing: 0,
            maxVerifierCut: _maxVerifierCut,
            thawingPeriod: _thawingPeriod,
            firstThawRequestId: bytes32(0),
            lastThawRequestId: bytes32(0),
            nThawRequests: 0
        });

        ServiceProviderInternal storage sp = serviceProviders[_serviceProvider];
        sp.tokensProvisioned = sp.tokensProvisioned + _tokens;

        emit ProvisionCreated(_serviceProvider, _verifier, _tokens, _maxVerifierCut, _thawingPeriod);
    }

    function _fulfillThawRequests(address _serviceProvider, address _verifier, uint256 _tokens) internal {
        Provision storage prov = provisions[_serviceProvider][_verifier];
        uint256 tokensRemaining = _tokens;
        uint256 sharesThawing = prov.sharesThawing;
        uint256 tokensThawing = prov.tokensThawing;
        while (tokensRemaining > 0) {
            require(prov.nThawRequests > 0, "not enough thawed tokens");
            bytes32 thawRequestId = prov.firstThawRequestId;
            ThawRequest storage thawRequest = thawRequests[thawRequestId];
            require(thawRequest.thawingUntil <= block.timestamp, "thawing period not over");
            uint256 thawRequestTokens = (thawRequest.shares * tokensThawing) / sharesThawing;
            if (thawRequestTokens <= tokensRemaining) {
                tokensRemaining = tokensRemaining - thawRequestTokens;
                delete thawRequests[thawRequestId];
                prov.firstThawRequestId = thawRequest.next;
                prov.nThawRequests -= 1;
                tokensThawing = tokensThawing - thawRequestTokens;
                sharesThawing = sharesThawing - thawRequest.shares;
                if (prov.nThawRequests == 0) {
                    prov.lastThawRequestId = bytes32(0);
                }
            } else {
                // TODO check for potential rounding issues
                uint256 sharesRemoved = (tokensRemaining * prov.sharesThawing) / prov.tokensThawing;
                thawRequest.shares = thawRequest.shares - sharesRemoved;
                tokensThawing = tokensThawing - tokensRemaining;
                sharesThawing = sharesThawing - sharesRemoved;
            }
            emit ProvisionThawFulfilled(
                _serviceProvider,
                _verifier,
                MathUtils.min(thawRequestTokens, tokensRemaining),
                thawRequestId
            );
        }
        prov.sharesThawing = sharesThawing;
        prov.tokensThawing = tokensThawing;
        prov.tokens = prov.tokens - _tokens;
    }

    function _addToProvision(address _serviceProvider, address _verifier, uint256 _tokens) internal {
        Provision storage prov = provisions[_serviceProvider][_verifier];
        require(_tokens > 0, "!tokens");
        require(getIdleStake(_serviceProvider) >= _tokens, "insufficient capacity");

        prov.tokens = prov.tokens + _tokens;
        serviceProviders[_serviceProvider].tokensProvisioned =
            serviceProviders[_serviceProvider].tokensProvisioned +
            _tokens;
        emit ProvisionIncreased(_serviceProvider, _verifier, _tokens);
    }

    /**
     * @dev Stake tokens on the service provider.
     * TODO: Move to HorizonStaking after the transition period
     * @param _serviceProvider Address of staking party
     * @param _tokens Amount of tokens to stake
     */
    function _stake(address _serviceProvider, uint256 _tokens) internal {
        // Deposit tokens into the indexer stake
        serviceProviders[_serviceProvider].tokensStaked = serviceProviders[_serviceProvider].tokensStaked + _tokens;

        emit StakeDeposited(_serviceProvider, _tokens);
    }

    function _graphToken() internal view returns (IGraphToken) {
        return IGraphToken(GRAPH_TOKEN);
    }
}
