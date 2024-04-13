// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.6.12 <0.9.0;
pragma abicoder v2;

import { IHorizonStakingTypes } from "./IHorizonStakingTypes.sol";

interface IHorizonStaking is IHorizonStakingTypes {

    /**
     * @dev Emitted when `serviceProvider` stakes `tokens` amount.
     */
    event StakeDeposited(address indexed serviceProvider, uint256 tokens);

    /**
     * @dev Emitted when `serviceProvider` withdraws `tokens` amount.
     */
    event StakeWithdrawn(address indexed serviceProvider, uint256 tokens);

    /**
     * @dev Emitted when `serviceProvider` locks `tokens` amount until `until`.
     */
    event StakeLocked(address indexed serviceProvider, uint256 tokens, uint256 until);

    /**
     * @dev Emitted when serviceProvider allows a verifier
     */
    event VerifierAllowed(address indexed serviceProvider, address indexed verifier);

    /**
     * @dev Emitted when serviceProvider denies a verifier
     */
    event VerifierDenied(address indexed serviceProvider, address indexed verifier);

    /**
     * @dev Emitted when an operator is allowed or denied by a service provider for a particular data service
     */
    event OperatorSet(address indexed serviceProvider, address indexed operator, address verifier, bool allowed);

    /**
     * @dev Emitted when a global operator (for all data services) is allowed or denied by a service provider
     */
    event GlobalOperatorSet(address indexed serviceProvider, address indexed operator, bool allowed);

    /**
     * @dev Emitted when a service provider provisions staked tokens to a verifier
     */
    event ProvisionCreated(
        address indexed serviceProvider,
        address indexed verifier,
        uint256 tokens,
        uint32 maxVerifierCut,
        uint64 thawingPeriod
    );

    /**
     * @dev Emitted when a service provider increases the tokens in a provision
     */
    event ProvisionIncreased(address indexed serviceProvider, address indexed verifier, uint256 tokens);

    /**
     * @dev Emitted when a thawing request is initiated by a service provider
     */
    event ProvisionThawInitiated(
        address indexed serviceProvider,
        address indexed verifier,
        uint256 tokens,
        uint64 thawingUntil,
        bytes32 indexed thawRequestId
    );

    /**
     * @dev Emitted when a service provider removes tokens from a provision after thawing
     */
    event ProvisionThawFulfilled(
        address indexed serviceProvider,
        address indexed verifier,
        uint256 tokens,
        bytes32 indexed thawRequestId
    );

    event ProvisionSlashed(address indexed serviceProvider, address indexed verifier, uint256 tokens);

    event DelegationSlashed(address indexed serviceProvider, address indexed verifier, uint256 tokens);

    event DelegationSlashingSkipped(address indexed serviceProvider, address indexed verifier, uint256 tokens);

    event VerifierCutSent(
        address indexed serviceProvider,
        address indexed verifier,
        address indexed destination,
        uint256 tokens
    );

    event TokensDelegated(
        address indexed serviceProvider,
        address indexed verifier,
        address indexed delegator,
        uint256 tokens
    );

    event TokensUndelegated(
        address indexed serviceProvider,
        address indexed verifier,
        address indexed delegator,
        uint256 tokens
    );

    event DelegatedTokensWithdrawn(
        address indexed serviceProvider,
        address indexed verifier,
        address indexed delegator,
        uint256 tokens
    );

    event DelegationSlashingEnabled(bool enabled);

    // whitelist/deny a verifier
    function allowVerifier(address _verifier) external;

    function denyVerifier(address _verifier) external;

    // deposit stake
    function stake(uint256 _tokens) external;

    function stakeTo(address _serviceProvider, uint256 _tokens) external;

    // can be called by anyone if the indexer has provisioned stake to this verifier
    function stakeToProvision(address _serviceProvider, address _verifier, uint256 _tokens) external;

    // create a provision
    function provision(
        address _serviceProvider,
        address _verifier,
        uint256 _tokens,
        uint32 _maxVerifierCut,
        uint64 _thawingPeriod
    ) external;

    // initiate a thawing to remove tokens from a provision
    function thaw(address _serviceProvider, address _verifier, uint256 _tokens) external returns (bytes32);

    // add more tokens from idle stake to an existing provision
    function addToProvision(address _serviceProvider, address _verifier, uint256 _tokens) external;

    // moves thawed stake from a provision back into the provider's available stake
    function deprovision(address _serviceProvider, address _verifier, uint256 _tokens) external;

    // moves thawed stake from one provision into another provision
    function reprovision(
        address _serviceProvider,
        address _oldVerifier,
        address _newVerifier,
        uint256 _tokens
    ) external;

    // moves thawed stake back to the owner's account - stake is removed from the protocol
    function unstake(address _serviceProvider, uint256 _tokens) external;

    // delegate tokens to a provider on a data service
    function delegate(address _serviceProvider, address _verifier, uint256 _tokens) external;

    // undelegate (thaw) delegated tokens from a provision
    function undelegate(address _serviceProvider, address _verifier, uint256 _shares) external;

    // withdraw delegated tokens after thawing
    function withdrawDelegated(address _serviceProvider, address _verifier, address _newServiceProvider) external;

    function slash(
        address _serviceProvider,
        uint256 _tokens,
        uint256 _verifierCutAmount,
        address _verifierCutDestination
    ) external;

    // staked tokens that are currently not provisioned, aka idle stake
    // `getStake(serviceProvider) - ServiceProvider.tokensProvisioned`
    function getIdleStake(address _serviceProvider) external view returns (uint256 tokens);

    /**
     * @notice Authorize or unauthorize an address to be an operator for the caller on a specific verifier / data service.
     * @param _operator Address to authorize or unauthorize
     * @param _allowed Whether the operator is authorized or not
     */
    function setOperator(address _operator, address _verifier, bool _allowed) external;

    /**
     * @notice Authorize or unauthorize an address to be an operator for the caller on all provisions.
     * @param _operator Address to authorize or unauthorize
     * @param _allowed Whether the operator is authorized or not
     */
    function setGlobalOperator(address _operator, bool _allowed) external;

    /**
     * @notice Check if an operator is authorized for the caller on all their allowlisted verifiers and global stake.
     * @param _operator The address to check for auth
     * @param _serviceProvider The service provider on behalf of whom they're claiming to act
     */
    function isGlobalAuthorized(address _operator, address _serviceProvider) external view returns (bool);

    /**
     * @notice Withdraw indexer tokens once the thawing period has passed.
     * @dev This is only needed during the transition period while we still have
     * a global lock. After that, unstake() will also withdraw.
     */
    function withdrawLocked(address _serviceProvider) external;

    function setDelegationSlashingEnabled(bool _enabled) external;
}
