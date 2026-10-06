// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title DARTVault
/// @notice Minimal vault with simulated internal value used to study revocable,
///         scoped delegation of authority from a USER to an AGENT, with a GUARDIAN
///         that may only revoke.
/// @dev Construction, delegation storage, `createDelegation`, `execute`
///      and one-way `revokeDelegation`. No restore, update, role change or upgrade path.
///      There is no owner, admin, upgrade path, role replacement or real value transfer.
///      Authentication relies on `msg.sender` of the signed Ethereum transaction:
///      the user's signed transaction plays the role of `Sign_skU` in the formal
///      model, and the stored delegation plays the role of the certificate D.
///      `tx.origin` is never used for authorization.
contract DARTVault {
    struct Delegation {
        address agent;
        address allowedRecipient;
        uint256 maxAmountPerAction;
        uint256 validAfter;
        uint256 validUntil;
        uint256 nonce;
        bool revoked;
        bool exists;
    }

    /// @notice The only identity allowed to grant authority.
    address public immutable user;
    /// @notice The identity that may only revoke existing authority.
    address public immutable guardian;
    /// @notice Simulated internal value. No ETH or tokens are held or moved.
    uint256 public simulatedBalance;
    /// @notice Grant counter. Starts at 0 and increases only on successful grants.
    uint256 public nextNonce;
    /// @notice Delegations keyed by their identifier (see `createDelegation`).
    mapping(bytes32 => Delegation) public delegations;

    event DelegationCreated(
        bytes32 indexed delegationId,
        address indexed grantor,
        address indexed agent,
        address allowedRecipient,
        uint256 maxAmountPerAction,
        uint256 validAfter,
        uint256 validUntil,
        uint256 nonce
    );

    event ActionExecuted(
        bytes32 indexed delegationId,
        address indexed agent,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    event DelegationRevoked(
        bytes32 indexed delegationId, address indexed revoker, uint256 timestamp, uint8 reasonCode
    );

    error ZeroAddress();
    error DuplicateRole();
    error NotUser();
    error InvalidAgent();
    error InvalidRecipient();
    error InvalidAmount();
    error InvalidTimeRange();
    error ExpiredAtCreation();

    // Execution-time errors. Kept distinct from grant-time errors so a test can
    // tell which rule rejected a call.
    error DelegationNotFound();
    error NotAgent();
    // Named `Revoked` (not `DelegationRevoked`) because Solidity does not allow an error
    // and an event to share a name, and the event keeps the spec's name.
    error Revoked();
    error NotYetValid();
    error Expired();
    error RecipientNotAllowed();
    error AmountExceedsLimit();
    error InsufficientBalance();

    // Revocation-time errors.
    error NotRevoker();
    error AlreadyRevoked();

    /// @param user_ Address that may grant delegations. Fixed for the contract lifetime.
    /// @param guardian_ Address reserved for revocation. Fixed for the contract lifetime.
    /// @param initialSimulatedBalance Starting simulated value. Zero is allowed.
    constructor(address user_, address guardian_, uint256 initialSimulatedBalance) {
        if (user_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (user_ == guardian_) revert DuplicateRole();
        user = user_;
        guardian = guardian_;
        simulatedBalance = initialSimulatedBalance;
    }

    /// @notice Grant scoped authority to `agent`. Only the user may call this.
    /// @dev Validation follows the locked Phase 0.5 rules. `allowedRecipient` is an
    ///      action label, not an authority role, so it may equal user, agent or guardian.
    ///      `validAfter` may be in the past (immediately active) or in the future.
    ///      A failed call reverts without touching `nextNonce`, storage or logs.
    function createDelegation(
        address agent,
        address allowedRecipient,
        uint256 maxAmountPerAction,
        uint256 validAfter,
        uint256 validUntil
    ) external returns (bytes32 delegationId) {
        if (msg.sender != user) revert NotUser();
        if (agent == address(0) || agent == user || agent == guardian) revert InvalidAgent();
        if (allowedRecipient == address(0)) revert InvalidRecipient();
        if (maxAmountPerAction == 0) revert InvalidAmount();
        if (validAfter >= validUntil) revert InvalidTimeRange();
        if (validUntil < block.timestamp) revert ExpiredAtCreation();

        uint256 nonce = nextNonce;

        // The identifier binds the delegation to this chain, this contract, the user
        // and every immutable term. The nonce makes repeated identical terms distinct.
        // `abi.encode` is used (not `encodePacked`) so fields cannot be ambiguous.
        // Mutable flags (`revoked`, `exists`) are deliberately excluded.
        delegationId = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                user,
                agent,
                allowedRecipient,
                maxAmountPerAction,
                validAfter,
                validUntil,
                nonce
            )
        );

        delegations[delegationId] = Delegation({
            agent: agent,
            allowedRecipient: allowedRecipient,
            maxAmountPerAction: maxAmountPerAction,
            validAfter: validAfter,
            validUntil: validUntil,
            nonce: nonce,
            revoked: false,
            exists: true
        });
        nextNonce = nonce + 1;

        emit DelegationCreated(
            delegationId,
            msg.sender,
            agent,
            allowedRecipient,
            maxAmountPerAction,
            validAfter,
            validUntil,
            nonce
        );
    }

    /// @notice Perform one simulated action under `delegationId`. Only the delegated
    ///         agent may call this, and only inside the delegation's scope and window.
    /// @dev Checks run cheapest-identity-first: existence, caller, revocation flag, time,
    ///      recipient, amount, balance. Each rule has its own error so tests can isolate it.
    ///      The window is inclusive at both ends (`validAfter <= t <= validUntil`), matching
    ///      the formal model `t0 <= t <= t1`. `revoked` is checked before time so a revoked
    ///      delegation fails for that reason even when its window is expired or not yet open.
    ///      The balance check is explicit rather than relying on 0.8 underflow panics, so
    ///      the failure is a named error, not a generic arithmetic panic.
    ///      No ETH or tokens move and no external call is made: `recipient` is a label
    ///      recorded in the event, nothing more.
    function execute(bytes32 delegationId, address recipient, uint256 amount) external {
        Delegation storage d = delegations[delegationId];
        if (!d.exists) revert DelegationNotFound();
        if (msg.sender != d.agent) revert NotAgent();
        if (d.revoked) revert Revoked();
        if (block.timestamp < d.validAfter) revert NotYetValid();
        if (block.timestamp > d.validUntil) revert Expired();
        if (recipient != d.allowedRecipient) revert RecipientNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (amount > d.maxAmountPerAction) revert AmountExceedsLimit();
        if (amount > simulatedBalance) revert InsufficientBalance();

        simulatedBalance -= amount;

        emit ActionExecuted(delegationId, msg.sender, recipient, amount, block.timestamp);
    }

    /// @notice Permanently invalidate `delegationId`. Callable by the user or the guardian.
    /// @dev This is the only power the guardian has, and it is one-way: nothing in this
    ///      contract clears `revoked`, and a later grant with identical terms gets a fresh
    ///      ID because `nextNonce` is part of the hash. Revocation works whether the window
    ///      is future, active or already expired, so an emergency does not depend on timing.
    ///      Revoking changes no balance, role, scope or time field: it cannot be used to
    ///      grant, spend or escalate. `reasonCode` is an opaque label recorded in the
    ///      event; it is not verified and does not prove an emergency is real.
    function revokeDelegation(bytes32 delegationId, uint8 reasonCode) external {
        Delegation storage d = delegations[delegationId];
        if (!d.exists) revert DelegationNotFound();
        if (msg.sender != user && msg.sender != guardian) revert NotRevoker();
        if (d.revoked) revert AlreadyRevoked();

        d.revoked = true;

        emit DelegationRevoked(delegationId, msg.sender, block.timestamp, reasonCode);
    }

    /// @notice Read a delegation as a struct (convenience over the mapping tuple getter).
    function getDelegation(bytes32 delegationId) external view returns (Delegation memory) {
        return delegations[delegationId];
    }
}
