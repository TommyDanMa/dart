// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {DARTVault} from "../src/DARTVault.sol";

/// @notice Cycle 1A tests: construction and user grant (TEST_PLAN T01, T08, T10, T13, T16).
///         Cycle 1B tests: agent execution, scope and time (T02, T03, T04, T05, T09, T13, T17, T19).
///         Cycle 1C tests: one-way revocation (T06, T07, T11, T12, T13, T14, T18).
///         Cycle 1D tests: precedence carry-overs, event completeness (T15) and
///         mutating-surface inspection of the compiled artifact (T20).
/// @dev Identities are local synthetic addresses from `makeAddr`. `vm.prank` only sets
///      `msg.sender` for the next call; it is a test-harness substitute for a signed
///      transaction and is not a cryptographic signature proof.
contract DARTVaultTest is Test {
    DARTVault internal vault;

    address internal user;
    address internal guardian;
    address internal agent;
    address internal recipient;
    address internal outsider;

    uint256 internal constant INITIAL_BALANCE = 100;
    uint256 internal constant MAX_AMOUNT = 10;
    uint256 internal constant NOW = 1_000_000;

    // Default valid terms: already active, expires well in the future.
    uint256 internal validAfter;
    uint256 internal validUntil;

    function setUp() public {
        user = makeAddr("user");
        guardian = makeAddr("guardian");
        agent = makeAddr("agent");
        recipient = makeAddr("recipient");
        outsider = makeAddr("outsider");

        vm.warp(NOW);
        validAfter = NOW - 100;
        validUntil = NOW + 1000;

        vault = new DARTVault(user, guardian, INITIAL_BALANCE);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /// @dev Independent recomputation of the identifier formula from IMPLEMENTATION_SPEC §4.
    function _expectedId(
        address agent_,
        address recipient_,
        uint256 maxAmount_,
        uint256 validAfter_,
        uint256 validUntil_,
        uint256 nonce_
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(vault),
                user,
                agent_,
                recipient_,
                maxAmount_,
                validAfter_,
                validUntil_,
                nonce_
            )
        );
    }

    /// @dev Grants with the default valid terms as the user and returns the ID.
    function _grantDefault() internal returns (bytes32) {
        vm.prank(user);
        return vault.createDelegation(agent, recipient, MAX_AMOUNT, validAfter, validUntil);
    }

    /// @dev Asserts a successful grant stored the given terms with the given nonce.
    function _assertStored(
        bytes32 id,
        address agent_,
        address recipient_,
        uint256 maxAmount_,
        uint256 validAfter_,
        uint256 validUntil_,
        uint256 nonce_
    ) internal view {
        DARTVault.Delegation memory d = vault.getDelegation(id);
        assertTrue(d.exists, "exists");
        assertFalse(d.revoked, "revoked");
        assertEq(d.agent, agent_, "agent");
        assertEq(d.allowedRecipient, recipient_, "allowedRecipient");
        assertEq(d.maxAmountPerAction, maxAmount_, "maxAmountPerAction");
        assertEq(d.validAfter, validAfter_, "validAfter");
        assertEq(d.validUntil, validUntil_, "validUntil");
        assertEq(d.nonce, nonce_, "nonce");
        assertEq(
            id, _expectedId(agent_, recipient_, maxAmount_, validAfter_, validUntil_, nonce_), "id"
        );
    }

    /// @dev Runs one grant attempt that must revert with `expectedError`, then checks
    ///      that nonce and balance are unchanged and that no log was emitted.
    ///      Every negative test uses valid terms except for the single check under test.
    function _assertGrantRejected(
        address caller,
        address agent_,
        address recipient_,
        uint256 maxAmount_,
        uint256 validAfter_,
        uint256 validUntil_,
        bytes4 expectedError
    ) internal {
        uint256 nonceBefore = vault.nextNonce();
        uint256 balanceBefore = vault.simulatedBalance();
        bytes32 wouldBeId =
            _expectedId(agent_, recipient_, maxAmount_, validAfter_, validUntil_, nonceBefore);

        vm.recordLogs();
        vm.prank(caller);
        vm.expectRevert(expectedError);
        vault.createDelegation(agent_, recipient_, maxAmount_, validAfter_, validUntil_);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event on failed grant");
        assertEq(vault.nextNonce(), nonceBefore, "nonce unchanged");
        assertEq(vault.simulatedBalance(), balanceBefore, "balance unchanged");
        assertFalse(vault.getDelegation(wouldBeId).exists, "no delegation written");
    }

    // ---------------------------------------------------------------------------
    // Constructor: positive
    // ---------------------------------------------------------------------------

    function test_Constructor_SetsRolesAndBalance() public view {
        assertEq(vault.user(), user);
        assertEq(vault.guardian(), guardian);
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE);
        assertEq(vault.nextNonce(), 0);
    }

    function test_Constructor_ZeroInitialBalanceAllowed() public {
        DARTVault v = new DARTVault(user, guardian, 0);
        assertEq(v.simulatedBalance(), 0);
        assertEq(v.nextNonce(), 0);
    }

    // ---------------------------------------------------------------------------
    // Constructor: negative (T16 role separation at construction)
    // ---------------------------------------------------------------------------

    function test_T16_Constructor_RevertsOnZeroUser() public {
        vm.expectRevert(DARTVault.ZeroAddress.selector);
        new DARTVault(address(0), guardian, INITIAL_BALANCE);
    }

    function test_T16_Constructor_RevertsOnZeroGuardian() public {
        vm.expectRevert(DARTVault.ZeroAddress.selector);
        new DARTVault(user, address(0), INITIAL_BALANCE);
    }

    function test_T16_Constructor_RevertsWhenUserEqualsGuardian() public {
        vm.expectRevert(DARTVault.DuplicateRole.selector);
        new DARTVault(user, user, INITIAL_BALANCE);
    }

    // ---------------------------------------------------------------------------
    // T01: valid user grant
    // ---------------------------------------------------------------------------

    function test_T01_UserGrant_StoresFieldsIncrementsNonceAndEmits() public {
        bytes32 expectedId = _expectedId(agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit DARTVault.DelegationCreated(
            expectedId, user, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0
        );

        bytes32 id = _grantDefault();

        assertEq(id, expectedId, "returned id");
        _assertStored(id, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0);
        assertEq(vault.nextNonce(), 1, "nonce incremented by 1");
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE, "balance unchanged");
    }

    function test_T01_PublicMappingGetterMatchesView() public {
        bytes32 id = _grantDefault();
        (
            address a,
            address r,
            uint256 m,
            uint256 va,
            uint256 vu,
            uint256 n,
            bool revoked,
            bool exists
        ) = vault.delegations(id);
        assertEq(a, agent);
        assertEq(r, recipient);
        assertEq(m, MAX_AMOUNT);
        assertEq(va, validAfter);
        assertEq(vu, validUntil);
        assertEq(n, 0);
        assertFalse(revoked);
        assertTrue(exists);
    }

    function test_T01_ImmediatelyActiveGrant() public {
        // validAfter strictly before block.timestamp is allowed.
        uint256 pastStart = NOW - 1;
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, pastStart, validUntil);
        _assertStored(id, agent, recipient, MAX_AMOUNT, pastStart, validUntil, 0);
    }

    function test_T01_FutureGrantSucceeds() public {
        // validAfter after block.timestamp is stored; it is simply not yet executable.
        uint256 futureStart = NOW + 1;
        uint256 futureEnd = NOW + 500;
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, futureStart, futureEnd);
        _assertStored(id, agent, recipient, MAX_AMOUNT, futureStart, futureEnd, 0);
    }

    function test_T01_ValidUntilEqualToNowSucceeds() public {
        // validUntil == block.timestamp is not expired at creation (inclusive window).
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, NOW - 10, NOW);
        _assertStored(id, agent, recipient, MAX_AMOUNT, NOW - 10, NOW, 0);
    }

    function test_T01_RecipientEqualToUserSucceeds() public {
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, user, MAX_AMOUNT, validAfter, validUntil);
        _assertStored(id, agent, user, MAX_AMOUNT, validAfter, validUntil, 0);
    }

    function test_T01_RecipientEqualToAgentSucceeds() public {
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, agent, MAX_AMOUNT, validAfter, validUntil);
        _assertStored(id, agent, agent, MAX_AMOUNT, validAfter, validUntil, 0);
    }

    function test_T01_RecipientEqualToGuardianSucceeds() public {
        // Recipient is an action label, not a role: matching the guardian grants it nothing.
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, guardian, MAX_AMOUNT, validAfter, validUntil);
        _assertStored(id, agent, guardian, MAX_AMOUNT, validAfter, validUntil, 0);
    }

    function test_T01_IdenticalTermsProduceDistinctIdsAndSuccessiveNonces() public {
        bytes32 id1 = _grantDefault();
        bytes32 id2 = _grantDefault();

        assertTrue(id1 != id2, "ids must differ");
        _assertStored(id1, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0);
        _assertStored(id2, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 1);
        assertEq(vault.nextNonce(), 2);
    }

    // ---------------------------------------------------------------------------
    // Unauthorized grantors (T08 / A6 guardian, T13 agent and outsider, T10 same calldata)
    // ---------------------------------------------------------------------------

    function test_T08_GuardianCannotGrant() public {
        _assertGrantRejected(
            guardian,
            agent,
            recipient,
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.NotUser.selector
        );
    }

    function test_T08_GuardianCannotGrantToItselfAsRecipient() public {
        _assertGrantRejected(
            guardian,
            agent,
            guardian,
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.NotUser.selector
        );
    }

    function test_T13_AgentCannotGrant() public {
        _assertGrantRejected(
            agent, agent, recipient, MAX_AMOUNT, validAfter, validUntil, DARTVault.NotUser.selector
        );
    }

    function test_T13_OutsiderCannotGrant() public {
        _assertGrantRejected(
            outsider,
            agent,
            recipient,
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.NotUser.selector
        );
    }

    function test_T10_GuardianSameCalldataAsUserIsRejected() public {
        // The user's grant succeeds; the guardian replaying identical arguments does not.
        bytes32 id = _grantDefault();
        assertEq(vault.nextNonce(), 1);

        _assertGrantRejected(
            guardian,
            agent,
            recipient,
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.NotUser.selector
        );
        // The user's delegation is untouched.
        _assertStored(id, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0);
    }

    // ---------------------------------------------------------------------------
    // T16: invalid terms from the legitimate user
    // ---------------------------------------------------------------------------

    function test_T16_RevertsOnZeroAgent() public {
        _assertGrantRejected(
            user,
            address(0),
            recipient,
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.InvalidAgent.selector
        );
    }

    function test_T16_RevertsWhenAgentIsUser() public {
        _assertGrantRejected(
            user,
            user,
            recipient,
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.InvalidAgent.selector
        );
    }

    function test_T16_RevertsWhenAgentIsGuardian() public {
        _assertGrantRejected(
            user,
            guardian,
            recipient,
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.InvalidAgent.selector
        );
    }

    function test_T16_RevertsOnZeroRecipient() public {
        _assertGrantRejected(
            user,
            agent,
            address(0),
            MAX_AMOUNT,
            validAfter,
            validUntil,
            DARTVault.InvalidRecipient.selector
        );
    }

    function test_T16_RevertsOnZeroMaxAmount() public {
        _assertGrantRejected(
            user, agent, recipient, 0, validAfter, validUntil, DARTVault.InvalidAmount.selector
        );
    }

    function test_T16_RevertsWhenValidAfterEqualsValidUntil() public {
        _assertGrantRejected(
            user,
            agent,
            recipient,
            MAX_AMOUNT,
            validUntil,
            validUntil,
            DARTVault.InvalidTimeRange.selector
        );
    }

    function test_T16_RevertsWhenValidAfterIsAfterValidUntil() public {
        _assertGrantRejected(
            user,
            agent,
            recipient,
            MAX_AMOUNT,
            validUntil + 1,
            validUntil,
            DARTVault.InvalidTimeRange.selector
        );
    }

    function test_T16_RevertsWhenExpiredAtCreation() public {
        // validUntil one second before block.timestamp; range itself is valid.
        _assertGrantRejected(
            user,
            agent,
            recipient,
            MAX_AMOUNT,
            NOW - 10,
            NOW - 1,
            DARTVault.ExpiredAtCreation.selector
        );
    }

    function test_FailedGrantDoesNotIncrementNonceOrEmit_ThenValidGrantUsesNonceZero() public {
        _assertGrantRejected(
            user, agent, recipient, 0, validAfter, validUntil, DARTVault.InvalidAmount.selector
        );
        // The next valid grant still consumes nonce 0.
        bytes32 id = _grantDefault();
        _assertStored(id, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0);
        assertEq(vault.nextNonce(), 1);
    }

    // ===========================================================================
    // Cycle 1B: execute
    // ===========================================================================

    /// @dev Hash of every stored field, used to prove a failed execute changes nothing.
    function _delegationSnapshot(bytes32 id) internal view returns (bytes32) {
        return keccak256(abi.encode(vault.getDelegation(id)));
    }

    /// @dev Runs one execute attempt that must revert with `expectedError`, then checks
    ///      balance, nonce and the whole delegation are unchanged and nothing was logged.
    ///      Callers set up a state that would succeed except for the one rule under test.
    function _assertExecuteRejected(
        address caller,
        bytes32 id,
        address recipient_,
        uint256 amount_,
        bytes4 expectedError
    ) internal {
        uint256 balanceBefore = vault.simulatedBalance();
        uint256 nonceBefore = vault.nextNonce();
        bytes32 snapshotBefore = _delegationSnapshot(id);

        vm.recordLogs();
        vm.prank(caller);
        vm.expectRevert(expectedError);
        vault.execute(id, recipient_, amount_);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event on failed execute");
        assertEq(vault.simulatedBalance(), balanceBefore, "balance unchanged");
        assertEq(vault.nextNonce(), nonceBefore, "nonce unchanged");
        assertEq(_delegationSnapshot(id), snapshotBefore, "delegation unchanged");
    }

    /// @dev Executes as the agent expecting success, checking the event and the exact
    ///      balance decrease. Nonce and delegation fields must not move.
    function _executeOk(bytes32 id, address recipient_, uint256 amount_) internal {
        uint256 balanceBefore = vault.simulatedBalance();
        uint256 nonceBefore = vault.nextNonce();
        bytes32 snapshotBefore = _delegationSnapshot(id);

        vm.expectEmit(true, true, true, true, address(vault));
        emit DARTVault.ActionExecuted(id, agent, recipient_, amount_, block.timestamp);

        vm.prank(agent);
        vault.execute(id, recipient_, amount_);

        assertEq(vault.simulatedBalance(), balanceBefore - amount_, "balance decreased by amount");
        assertEq(vault.nextNonce(), nonceBefore, "nonce unchanged by execute");
        assertEq(_delegationSnapshot(id), snapshotBefore, "delegation unchanged by execute");
    }

    // ---------------------------------------------------------------------------
    // T02 / T04 / T05 / T19: positive execution
    // ---------------------------------------------------------------------------

    function test_T02_ValidActionReducesBalanceAndEmits() public {
        bytes32 id = _grantDefault();
        _executeOk(id, recipient, 7);
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE - 7);
    }

    function test_T04_AmountEqualToMaxSucceeds() public {
        bytes32 id = _grantDefault();
        _executeOk(id, recipient, MAX_AMOUNT);
    }

    function test_T05_TimestampEqualToValidAfterSucceeds() public {
        // Future window so the lower bound is reachable by an isolated warp.
        uint256 start = NOW + 50;
        uint256 end = NOW + 500;
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, start, end);

        vm.warp(start);
        _executeOk(id, recipient, 1);
    }

    function test_T05_TimestampEqualToValidUntilSucceeds() public {
        bytes32 id = _grantDefault();
        vm.warp(validUntil);
        _executeOk(id, recipient, 1);
    }

    function test_T19_RepeatedValidExecutesSucceedWhileBalanceLasts() public {
        bytes32 id = _grantDefault();
        _executeOk(id, recipient, MAX_AMOUNT);
        _executeOk(id, recipient, MAX_AMOUNT);
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE - 2 * MAX_AMOUNT);
    }

    function test_T17_T19_ExecutesDrainBalanceToZeroThenStop() public {
        // Balance 15, max 10: 10 ok, 10 fails on balance, 5 ok, then nothing more.
        vault = new DARTVault(user, guardian, 15);
        bytes32 id = _grantDefault();

        _executeOk(id, recipient, MAX_AMOUNT);
        _assertExecuteRejected(
            agent, id, recipient, MAX_AMOUNT, DARTVault.InsufficientBalance.selector
        );
        _executeOk(id, recipient, 5);
        assertEq(vault.simulatedBalance(), 0);
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.InsufficientBalance.selector);
    }

    function test_T02_RecipientEqualToUserOnlyReducesSimulatedBalance() public {
        _assertRoleRecipientExecuteIsPureBookkeeping(user);
    }

    function test_T02_RecipientEqualToAgentOnlyReducesSimulatedBalance() public {
        _assertRoleRecipientExecuteIsPureBookkeeping(agent);
    }

    function test_T02_RecipientEqualToGuardianOnlyReducesSimulatedBalance() public {
        _assertRoleRecipientExecuteIsPureBookkeeping(guardian);
    }

    /// @dev Recipient is a label. Executing towards a role address must change only the
    ///      simulated balance: no ETH moves, roles and nonce stay, delegation stays.
    function _assertRoleRecipientExecuteIsPureBookkeeping(address roleRecipient) internal {
        vm.prank(user);
        bytes32 id =
            vault.createDelegation(agent, roleRecipient, MAX_AMOUNT, validAfter, validUntil);

        uint256 recipientEthBefore = roleRecipient.balance;
        _executeOk(id, roleRecipient, MAX_AMOUNT);

        assertEq(vault.simulatedBalance(), INITIAL_BALANCE - MAX_AMOUNT);
        assertEq(address(vault).balance, 0, "vault holds no ETH");
        assertEq(roleRecipient.balance, recipientEthBefore, "recipient received no ETH");
        assertEq(vault.user(), user, "user unchanged");
        assertEq(vault.guardian(), guardian, "guardian unchanged");
    }

    // ---------------------------------------------------------------------------
    // T13 / T09: wrong identity
    // ---------------------------------------------------------------------------

    function test_T13_UnknownIdIsRejected() public {
        _grantDefault();
        bytes32 unknownId = keccak256("no such delegation");
        _assertExecuteRejected(
            agent, unknownId, recipient, 1, DARTVault.DelegationNotFound.selector
        );
    }

    function test_T13_WrongAgentIsRejected() public {
        bytes32 id = _grantDefault();
        address otherAgent = makeAddr("otherAgent");
        _assertExecuteRejected(otherAgent, id, recipient, 1, DARTVault.NotAgent.selector);
    }

    function test_T13_OutsiderCannotExecute() public {
        bytes32 id = _grantDefault();
        _assertExecuteRejected(outsider, id, recipient, 1, DARTVault.NotAgent.selector);
    }

    function test_T09_GuardianCannotExecute() public {
        // A7: the guardian attempting to spend under an active agent delegation.
        bytes32 id = _grantDefault();
        _assertExecuteRejected(guardian, id, recipient, 1, DARTVault.NotAgent.selector);
    }

    function test_T13_UserCannotExecuteAgentDelegation() public {
        bytes32 id = _grantDefault();
        _assertExecuteRejected(user, id, recipient, 1, DARTVault.NotAgent.selector);
    }

    // ---------------------------------------------------------------------------
    // T03 / T04 / T05 / T17: out of scope, amount, time, balance
    // ---------------------------------------------------------------------------

    function test_T03_WrongRecipientIsRejected() public {
        bytes32 id = _grantDefault();
        address otherRecipient = makeAddr("otherRecipient");
        _assertExecuteRejected(agent, id, otherRecipient, 1, DARTVault.RecipientNotAllowed.selector);
    }

    function test_T04_AmountAboveMaxIsRejected() public {
        bytes32 id = _grantDefault();
        _assertExecuteRejected(
            agent, id, recipient, MAX_AMOUNT + 1, DARTVault.AmountExceedsLimit.selector
        );
    }

    function test_T17_ZeroAmountIsRejected() public {
        bytes32 id = _grantDefault();
        _assertExecuteRejected(agent, id, recipient, 0, DARTVault.InvalidAmount.selector);
    }

    function test_T05_BeforeValidAfterIsRejected() public {
        uint256 start = NOW + 50;
        uint256 end = NOW + 500;
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, start, end);

        vm.warp(start - 1);
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.NotYetValid.selector);
    }

    function test_T05_AfterValidUntilIsRejected() public {
        bytes32 id = _grantDefault();
        vm.warp(validUntil + 1);
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.Expired.selector);
    }

    function test_T17_AmountWithinMaxButAboveBalanceIsRejected() public {
        // Max is above the vault balance so the balance rule is the only failing one.
        uint256 bigMax = INITIAL_BALANCE + 1;
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, bigMax, validAfter, validUntil);
        _assertExecuteRejected(
            agent, id, recipient, INITIAL_BALANCE + 1, DARTVault.InsufficientBalance.selector
        );
    }

    function test_FailedExecuteKeepsBalance_ThenValidExecuteStillWorks() public {
        bytes32 id = _grantDefault();
        _assertExecuteRejected(
            agent, id, recipient, MAX_AMOUNT + 1, DARTVault.AmountExceedsLimit.selector
        );
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE);
        _executeOk(id, recipient, MAX_AMOUNT);
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE - MAX_AMOUNT);
    }

    // ===========================================================================
    // Cycle 1C: revokeDelegation
    // ===========================================================================

    uint8 internal constant REASON_NONE = 0;
    uint8 internal constant REASON_COMPROMISED = 7;

    /// @dev Revokes as `caller` expecting success. Checks the event, that `revoked`
    ///      flipped to true, and that every other delegation field, the balance, the
    ///      nonce and both roles are unchanged.
    function _revokeOk(address caller, bytes32 id, uint8 reasonCode) internal {
        uint256 balanceBefore = vault.simulatedBalance();
        uint256 nonceBefore = vault.nextNonce();
        DARTVault.Delegation memory pre = vault.getDelegation(id);
        assertFalse(pre.revoked, "precondition: not yet revoked");

        vm.expectEmit(true, true, true, true, address(vault));
        emit DARTVault.DelegationRevoked(id, caller, block.timestamp, reasonCode);

        vm.prank(caller);
        vault.revokeDelegation(id, reasonCode);

        DARTVault.Delegation memory post = vault.getDelegation(id);
        assertTrue(post.revoked, "revoked flag set");
        // Every other field must be identical: compare against the pre-state with only
        // the revoked bit flipped.
        pre.revoked = true;
        assertEq(keccak256(abi.encode(post)), keccak256(abi.encode(pre)), "only revoked changed");

        assertEq(vault.simulatedBalance(), balanceBefore, "balance unchanged by revoke");
        assertEq(vault.nextNonce(), nonceBefore, "nonce unchanged by revoke");
        assertEq(vault.user(), user, "user unchanged");
        assertEq(vault.guardian(), guardian, "guardian unchanged");
    }

    /// @dev Runs one revoke attempt that must revert with `expectedError`, then checks
    ///      the delegation, balance and nonce are unchanged and nothing was logged.
    function _assertRevokeRejected(
        address caller,
        bytes32 id,
        uint8 reasonCode,
        bytes4 expectedError
    ) internal {
        uint256 balanceBefore = vault.simulatedBalance();
        uint256 nonceBefore = vault.nextNonce();
        bytes32 snapshotBefore = _delegationSnapshot(id);

        vm.recordLogs();
        vm.prank(caller);
        vm.expectRevert(expectedError);
        vault.revokeDelegation(id, reasonCode);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event on failed revoke");
        assertEq(vault.simulatedBalance(), balanceBefore, "balance unchanged");
        assertEq(vault.nextNonce(), nonceBefore, "nonce unchanged");
        assertEq(_delegationSnapshot(id), snapshotBefore, "delegation unchanged");
        assertEq(vault.user(), user, "user unchanged");
        assertEq(vault.guardian(), guardian, "guardian unchanged");
    }

    // ---------------------------------------------------------------------------
    // T06 and authorized revocation in every window state
    // ---------------------------------------------------------------------------

    function test_T06_GuardianRevokesActiveDelegation() public {
        bytes32 id = _grantDefault();
        _revokeOk(guardian, id, REASON_COMPROMISED);
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE);
    }

    function test_T06_UserRevokesActiveDelegation() public {
        bytes32 id = _grantDefault();
        _revokeOk(user, id, REASON_NONE);
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE);
    }

    function test_T06_RevokeFutureDelegationSucceeds() public {
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, NOW + 50, NOW + 500);
        assertLt(block.timestamp, NOW + 50, "precondition: window not started");
        _revokeOk(guardian, id, REASON_COMPROMISED);
    }

    function test_T06_RevokeExpiredDelegationSucceeds() public {
        bytes32 id = _grantDefault();
        vm.warp(validUntil + 1);
        _revokeOk(guardian, id, REASON_COMPROMISED);
    }

    function test_T06_ReasonCodeIsOnlyALabel() public {
        // Zero and non-zero codes both succeed; the code grants nothing and proves nothing.
        bytes32 id1 = _grantDefault();
        bytes32 id2 = _grantDefault();
        _revokeOk(guardian, id1, 0);
        _revokeOk(guardian, id2, type(uint8).max);
    }

    // ---------------------------------------------------------------------------
    // T11 / T18 / T12: emergency without the user, targeted revoke, no reactivation
    // ---------------------------------------------------------------------------

    function test_T11_UserUnavailable_GuardianRevokes_AgentBlocked() public {
        // A8: after granting, the user makes no further call. The agent acts once
        // legitimately, the guardian then revokes, and the agent is blocked in-window.
        bytes32 id = _grantDefault();
        _executeOk(id, recipient, MAX_AMOUNT);

        _revokeOk(guardian, id, REASON_COMPROMISED);

        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.Revoked.selector);
        assertEq(vault.simulatedBalance(), INITIAL_BALANCE - MAX_AMOUNT, "no spend after revoke");
    }

    function test_T18_RevokingD1LeavesD2Executable() public {
        bytes32 id1 = _grantDefault();
        bytes32 id2 = _grantDefault();

        _revokeOk(guardian, id1, REASON_COMPROMISED);

        _assertExecuteRejected(agent, id1, recipient, 1, DARTVault.Revoked.selector);
        _executeOk(id2, recipient, MAX_AMOUNT);
        assertFalse(vault.getDelegation(id2).revoked, "D2 untouched");
    }

    function test_T12_NewGrantWithIdenticalTermsDoesNotReviveRevokedId() public {
        // A9: the user may re-grant, but the old ID stays dead and the new one is distinct.
        bytes32 id1 = _grantDefault();
        _revokeOk(guardian, id1, REASON_COMPROMISED);

        bytes32 id2 = _grantDefault();
        assertTrue(id1 != id2, "new ID");
        _assertStored(id2, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 1);
        assertTrue(vault.getDelegation(id1).revoked, "old ID still revoked");

        _assertExecuteRejected(agent, id1, recipient, 1, DARTVault.Revoked.selector);
        _executeOk(id2, recipient, MAX_AMOUNT);
    }

    // ---------------------------------------------------------------------------
    // T07: execute after revoke
    // ---------------------------------------------------------------------------

    function test_T07_AgentExecuteAfterRevokeFailsInWindow() public {
        bytes32 id = _grantDefault();
        _revokeOk(guardian, id, REASON_COMPROMISED);
        // Same call that succeeded before revocation, still in-window.
        _assertExecuteRejected(agent, id, recipient, MAX_AMOUNT, DARTVault.Revoked.selector);
    }

    function test_T07_RevokedStaysRevokedAcrossTimeWarps() public {
        // Revoke a future delegation, then warp into what would have been its valid
        // window and past its end: the revocation check runs before the time checks.
        uint256 start = NOW + 50;
        uint256 end = NOW + 500;
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, start, end);
        _revokeOk(user, id, REASON_NONE);

        vm.warp(start);
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.Revoked.selector);
        vm.warp(end);
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.Revoked.selector);
        vm.warp(end + 1);
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.Revoked.selector);
    }

    // ---------------------------------------------------------------------------
    // T14 / T13: duplicate, unknown and unauthorized revocation
    // ---------------------------------------------------------------------------

    function test_T14_UserThenGuardianDuplicateRevokeIsRejected() public {
        bytes32 id = _grantDefault();
        _revokeOk(user, id, REASON_NONE);
        _assertRevokeRejected(guardian, id, REASON_COMPROMISED, DARTVault.AlreadyRevoked.selector);
    }

    function test_T14_GuardianTwiceDuplicateRevokeIsRejected() public {
        bytes32 id = _grantDefault();
        _revokeOk(guardian, id, REASON_COMPROMISED);
        _assertRevokeRejected(guardian, id, REASON_COMPROMISED, DARTVault.AlreadyRevoked.selector);
    }

    function test_T14_UnknownIdRevokeIsRejected() public {
        _grantDefault();
        bytes32 unknownId = keccak256("no such delegation");
        _assertRevokeRejected(
            guardian, unknownId, REASON_COMPROMISED, DARTVault.DelegationNotFound.selector
        );
    }

    function test_T13_AgentCannotRevoke() public {
        bytes32 id = _grantDefault();
        _assertRevokeRejected(agent, id, REASON_COMPROMISED, DARTVault.NotRevoker.selector);
        // The delegation remains fully usable.
        _executeOk(id, recipient, 1);
    }

    function test_T13_OutsiderCannotRevoke() public {
        bytes32 id = _grantDefault();
        _assertRevokeRejected(outsider, id, REASON_COMPROMISED, DARTVault.NotRevoker.selector);
        _executeOk(id, recipient, 1);
    }

    function test_FailedRevokeKeepsState_ThenAuthorizedRevokeWorks() public {
        bytes32 id = _grantDefault();
        _assertRevokeRejected(agent, id, REASON_COMPROMISED, DARTVault.NotRevoker.selector);
        assertFalse(vault.getDelegation(id).revoked);
        _revokeOk(guardian, id, REASON_COMPROMISED);
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.Revoked.selector);
    }

    // ===========================================================================
    // Cycle 1D: precedence carry-overs, T15 event completeness, T20 surface
    // ===========================================================================

    // ---------------------------------------------------------------------------
    // Carry-over P2 from Cycle 1C: check-order precedence
    // ---------------------------------------------------------------------------

    function test_T07_FutureRevokedExecuteFailsRevokedBeforeWindowOpens() public {
        // Window not yet open AND revoked: the revocation check must win. If
        // `NotYetValid` were checked before `Revoked`, this test would fail.
        uint256 start = NOW + 50;
        uint256 end = NOW + 500;
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, start, end);
        _revokeOk(guardian, id, REASON_COMPROMISED);

        assertLt(block.timestamp, start, "precondition: still before validAfter");
        _assertExecuteRejected(agent, id, recipient, 1, DARTVault.Revoked.selector);
    }

    function test_T14_UnknownIdRevokeByOutsiderIsNotFound() public {
        // Unknown ID AND unauthorized caller: existence is checked first. If
        // `NotRevoker` were checked before `DelegationNotFound`, this test would fail.
        _grantDefault();
        bytes32 unknownId = keccak256("no such delegation");
        _assertRevokeRejected(
            outsider, unknownId, REASON_COMPROMISED, DARTVault.DelegationNotFound.selector
        );
    }

    // ---------------------------------------------------------------------------
    // T15: every successful transition emits its event (rejected calls emit nothing)
    // ---------------------------------------------------------------------------

    function test_T15_SuccessfulGrantExecuteRevokeEachEmitTheirEvent() public {
        bytes32 expectedId = _expectedId(agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0);

        vm.recordLogs();

        // 1. Grant by the user.
        vm.expectEmit(true, true, true, true, address(vault));
        emit DARTVault.DelegationCreated(
            expectedId, user, agent, recipient, MAX_AMOUNT, validAfter, validUntil, 0
        );
        vm.prank(user);
        bytes32 id = vault.createDelegation(agent, recipient, MAX_AMOUNT, validAfter, validUntil);
        assertEq(id, expectedId);

        // 2. Execute by the agent.
        vm.expectEmit(true, true, true, true, address(vault));
        emit DARTVault.ActionExecuted(id, agent, recipient, MAX_AMOUNT, block.timestamp);
        vm.prank(agent);
        vault.execute(id, recipient, MAX_AMOUNT);

        // 3. Revoke by the guardian.
        vm.expectEmit(true, true, true, true, address(vault));
        emit DARTVault.DelegationRevoked(id, guardian, block.timestamp, REASON_COMPROMISED);
        vm.prank(guardian);
        vault.revokeDelegation(id, REASON_COMPROMISED);

        // Exactly three logs from the vault, in order. The recorder also captures the
        // reference events this test emits for `expectEmit`, so filter by emitter.
        Vm.Log[] memory all = vm.getRecordedLogs();
        Vm.Log[] memory logs = new Vm.Log[](3);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].emitter != address(vault)) continue;
            assertLt(n, 3, "more than three vault events");
            logs[n++] = all[i];
        }
        assertEq(n, 3, "one event per successful transition");
        assertEq(logs[0].topics[0], DARTVault.DelegationCreated.selector);
        assertEq(logs[1].topics[0], DARTVault.ActionExecuted.selector);
        assertEq(logs[2].topics[0], DARTVault.DelegationRevoked.selector);
        assertEq(logs[0].topics[1], id, "created: delegationId topic");
        assertEq(logs[1].topics[1], id, "executed: delegationId topic");
        assertEq(logs[2].topics[1], id, "revoked: delegationId topic");

        assertEq(vault.simulatedBalance(), INITIAL_BALANCE - MAX_AMOUNT);
        assertTrue(vault.getDelegation(id).revoked);
    }

    // ---------------------------------------------------------------------------
    // T20: mutating surface read from the compiled artifact (not from unknown
    // selectors reverting). Requires read access to ./out in foundry.toml.
    // ---------------------------------------------------------------------------

    function test_T20_CompiledAbiMutatorsAreExactlyGrantExecuteRevoke() public view {
        string memory json = vm.readFile("out/DARTVault.sol/DARTVault.json");

        uint256 mutators;
        uint256 functions;
        bool sawCreate;
        bool sawExecute;
        bool sawRevoke;

        for (uint256 i = 0;; i++) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, entry)) break;

            string memory kind = vm.parseJsonString(json, string.concat(entry, ".type"));
            // No implicit entry points: a fallback or receive would be a hidden mutator.
            assertFalse(_eq(kind, "fallback"), "fallback present");
            assertFalse(_eq(kind, "receive"), "receive present");
            if (!_eq(kind, "function")) continue;

            functions++;
            string memory name = vm.parseJsonString(json, string.concat(entry, ".name"));
            _assertNoForbiddenFragment(name);

            string memory mutability =
                vm.parseJsonString(json, string.concat(entry, ".stateMutability"));
            if (_eq(mutability, "view") || _eq(mutability, "pure")) continue;

            // Anything not view/pure (nonpayable or payable) can change state.
            mutators++;
            if (_eq(name, "createDelegation")) sawCreate = true;
            else if (_eq(name, "execute")) sawExecute = true;
            else if (_eq(name, "revokeDelegation")) sawRevoke = true;
            else revert(string.concat("unexpected mutating function: ", name));
        }

        assertGt(functions, 0, "artifact ABI parsed");
        assertEq(mutators, 3, "exactly three mutating functions");
        assertTrue(sawCreate, "createDelegation present");
        assertTrue(sawExecute, "execute present");
        assertTrue(sawRevoke, "revokeDelegation present");
    }

    /// @dev Case-insensitive check that an ABI function name carries none of the
    ///      fragments that would signal a restore, upgrade or role-change path.
    function _assertNoForbiddenFragment(string memory name) internal pure {
        string memory lower = _toLower(name);
        string[7] memory forbidden = [
            "restore", "unrevoke", "upgrade", "setuser", "setguardian", "transferownership", "owner"
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            assertFalse(
                _contains(lower, forbidden[i]),
                string.concat("forbidden name fragment in ABI: ", name)
            );
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Returns a lowercased copy. `bytes(s)` aliases the input, so copy first.
    function _toLower(string memory s) internal pure returns (string memory) {
        bytes memory src = bytes(s);
        bytes memory b = new bytes(src.length);
        for (uint256 i = 0; i < src.length; i++) {
            b[i] = (src[i] >= 0x41 && src[i] <= 0x5A) ? bytes1(uint8(src[i]) + 32) : src[i];
        }
        return string(b);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
