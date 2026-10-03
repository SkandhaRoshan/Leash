// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Leash} from "../src/Leash.sol";
import {ERC8004ReputationAdapter} from "../src/adapters/ERC8004ReputationAdapter.sol";
import {
    MockUSDG,
    MockReputation,
    MockERC8004Registry,
    MockIdentity,
    MockIncidentIdentity,
    MockIncidentRegistry
} from "./mocks/Mocks.sol";

contract LeashTest is Test {
    event PaymentBlocked(address indexed agent, address indexed to, uint256 amount, bytes32 reasonCode);
    event AgentAutoRevoked(address indexed agent, uint256 strikes);
    event IncidentReported(address indexed agent, uint256 indexed agentId, bool success);
    event IncidentReportFailed(address indexed agent, uint256 indexed agentId);

    Leash leash;
    MockUSDG usdg;
    MockReputation rep;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address merchant = makeAddr("merchant");
    address stranger = makeAddr("stranger");
    address attacker = makeAddr("attacker");

    uint256 constant U = 1e6; // 1 USDG

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockUSDG();
        leash = new Leash(address(usdg), owner);
        rep = new MockReputation();
        usdg.mint(address(leash), 1000 * U);

        vm.startPrank(owner);
        leash.setAllowed(merchant, true);
        leash.setReputationSource(address(rep));
        leash.setPolicy(agent, _policy(10 * U, 25 * U, 5 * U, 0));
        vm.stopPrank();
    }

    function _policy(uint256 perTx, uint256 window, uint256 approval, uint8 minTrust)
        internal
        view
        returns (Leash.Policy memory)
    {
        return Leash.Policy({
            active: true,
            expiry: uint64(block.timestamp + 7 days),
            perTxCap: uint128(perTx),
            windowCap: uint128(window),
            approvalThreshold: uint128(approval),
            minTrust: minTrust
        });
    }

    function _expectBlocked(address caller, address attemptedAgent, address to, uint256 amount, bytes32 reasonCode)
        internal
        returns (bool)
    {
        address eventAgent = attemptedAgent == caller ? attemptedAgent : caller;
        vm.expectEmit(true, true, false, true, address(leash));
        emit PaymentBlocked(eventAgent, to, amount, reasonCode);
        vm.prank(caller);
        return leash.tryPay(attemptedAgent, to, amount);
    }

    function _incidentSetup(uint256 agentId) internal returns (MockIncidentIdentity identity, MockIncidentRegistry registry) {
        identity = new MockIncidentIdentity();
        identity.mint(agentId, agent);
        registry = new MockIncidentRegistry(address(identity));
        vm.startPrank(owner);
        leash.setFeedbackRegistry(address(registry));
        leash.linkAgentId(agent, agentId);
        vm.stopPrank();
    }

    function _eventExists(Vm.Log[] memory logs, bytes32 eventTopic) internal pure returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == eventTopic) return true;
        }
        return false;
    }

    function _policyIsActive(address account) internal view returns (bool active) {
        (active,,,,,) = leash.policies(account);
    }

    // ------------------------------------------------------------ happy path
    function test_payWithinPolicy() public {
        vm.prank(agent);
        uint256 id = leash.pay(merchant, 3 * U, "api-call");
        assertEq(id, 0);
        assertEq(usdg.balanceOf(merchant), 3 * U);
        assertEq(leash.windowSpent(agent), 3 * U);
        assertEq(leash.remainingAllowance(agent), 22 * U);
    }

    // --------------------------------------------------------- blocked attacks
    function test_revert_overPerTxCap() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Leash.ExceedsPerTxCap.selector, 11 * U, 10 * U));
        leash.pay(merchant, 11 * U, "");
    }

    function test_revert_overRollingWindow() public {
        vm.startPrank(agent);
        leash.pay(merchant, 5 * U, "");
        leash.pay(merchant, 5 * U, "");
        leash.pay(merchant, 5 * U, "");
        leash.pay(merchant, 5 * U, "");
        leash.pay(merchant, 5 * U, ""); // 25 total = cap
        vm.expectRevert(abi.encodeWithSelector(Leash.WindowCapExceeded.selector, 25 * U, 1, 25 * U));
        leash.pay(merchant, 1, "");
        vm.stopPrank();
    }

    function test_windowRollsForward() public {
        vm.startPrank(agent);
        for (uint256 i; i < 5; i++) leash.pay(merchant, 5 * U, "");
        vm.warp(block.timestamp + 25 hours);
        leash.pay(merchant, 5 * U, ""); // old spend aged out
        vm.stopPrank();
        assertEq(leash.windowSpent(agent), 5 * U);
    }

    function test_revert_unknownCounterparty() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Leash.NotAllowlisted.selector, stranger));
        leash.pay(stranger, 1 * U, "");
    }

    function test_revert_nonAgent() public {
        vm.prank(attacker);
        vm.expectRevert(Leash.NotAgent.selector);
        leash.pay(merchant, 1 * U, "");
    }

    function test_revert_afterExpiry() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(agent);
        vm.expectRevert(Leash.PolicyExpired.selector);
        leash.pay(merchant, 1 * U, "");
    }

    function test_revert_afterRevoke() public {
        vm.prank(owner);
        leash.revoke(agent);
        vm.prank(agent);
        vm.expectRevert(Leash.NotAgent.selector);
        leash.pay(merchant, 1 * U, "");
    }

    function test_revert_denylistBeatsAllowlist() public {
        vm.prank(owner);
        leash.setDenied(merchant, true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Leash.CounterpartyDenied.selector, merchant));
        leash.pay(merchant, 1 * U, "");
    }

    function test_revert_zeroAmount() public {
        vm.prank(agent);
        vm.expectRevert(Leash.ZeroAmount.selector);
        leash.pay(merchant, 0, "");
    }

    function test_revert_whenPaused() public {
        vm.prank(owner);
        leash.pause();
        vm.prank(agent);
        vm.expectRevert();
        leash.pay(merchant, 1 * U, "");
    }

    function test_tryPay_recordsBlockedEventWithReason_NotAllowlisted() public {
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_ExceedsPerTxCap() public {
        assertFalse(_expectBlocked(agent, agent, merchant, 11 * U, leash.REASON_EXCEEDS_PER_TX_CAP()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_WindowCapExceeded() public {
        vm.startPrank(agent);
        for (uint256 i; i < 5; i++) leash.pay(merchant, 5 * U, "");
        vm.stopPrank();

        assertFalse(_expectBlocked(agent, agent, merchant, U, leash.REASON_WINDOW_CAP_EXCEEDED()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_PolicyExpired() public {
        vm.warp(block.timestamp + 8 days);
        assertFalse(_expectBlocked(agent, agent, merchant, U, leash.REASON_POLICY_EXPIRED()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_NotAgent() public {
        assertFalse(_expectBlocked(attacker, attacker, merchant, U, leash.REASON_NOT_AGENT()));
        assertEq(leash.strikes(attacker), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_Paused() public {
        vm.prank(owner);
        leash.pause();
        assertFalse(_expectBlocked(agent, agent, merchant, U, leash.REASON_PAUSED()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_ZeroAmount() public {
        assertFalse(_expectBlocked(agent, agent, merchant, 0, leash.REASON_ZERO_AMOUNT()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_Denylisted() public {
        vm.prank(owner);
        leash.setDenied(merchant, true);
        assertFalse(_expectBlocked(agent, agent, merchant, U, leash.REASON_DENYLISTED()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_recordsBlockedEventWithReason_LowTrust() public {
        vm.prank(owner);
        leash.setPolicy(agent, _policy(10 * U, 25 * U, 5 * U, 80));
        rep.set(stranger, 50);
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_LOW_TRUST()));
        assertEq(leash.strikes(agent), 1);
    }

    function test_tryPay_incrementsStrikes() public {
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        assertEq(leash.strikes(agent), 2);
    }

    function test_tryPay_autoRevokesAfterMaxStrikes() public {
        vm.prank(owner);
        leash.setMaxStrikes(3);
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));

        vm.recordLogs();
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventTopic = keccak256("AgentAutoRevoked(address,uint256)");
        bool foundAutoRevoke;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics.length == 2 && entries[i].topics[0] == eventTopic) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), agent);
                assertEq(abi.decode(entries[i].data, (uint256)), 3);
                foundAutoRevoke = true;
            }
        }
        assertTrue(foundAutoRevoke);
        assertEq(leash.strikes(agent), 3);

        assertFalse(_expectBlocked(agent, agent, merchant, U, leash.REASON_NOT_AGENT()));
        assertEq(leash.strikes(agent), 4);
    }

    function test_tryPay_doesNotAutoRevokeBelowMax() public {
        vm.prank(owner);
        leash.setMaxStrikes(3);
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));

        vm.prank(agent);
        assertEq(leash.pay(merchant, U, ""), 0);
        (bool active,,,,,) = leash.policies(agent);
        assertTrue(active);
    }

    function test_resetStrikes() public {
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        assertFalse(_expectBlocked(agent, agent, stranger, U, leash.REASON_NOT_ALLOWLISTED()));
        vm.prank(owner);
        leash.resetStrikes(agent);
        assertEq(leash.getStrikes(agent), 0);

        vm.prank(agent);
        assertEq(leash.pay(merchant, U, ""), 0);
    }

    function test_setMaxStrikes_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "MaxStrikes out of bounds"));
        leash.setMaxStrikes(0);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "MaxStrikes out of bounds"));
        leash.setMaxStrikes(11);
        leash.setMaxStrikes(5);
        vm.stopPrank();
        assertEq(leash.maxStrikes(), 5);
    }

    function test_tryPay_successPath() public {
        vm.recordLogs();
        vm.prank(agent);
        assertTrue(leash.tryPay(agent, merchant, U));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 blockedTopic = keccak256("PaymentBlocked(address,address,uint256,bytes32)");
        for (uint256 i; i < entries.length; i++) assertTrue(entries[i].topics[0] != blockedTopic);
        assertEq(leash.strikes(agent), 0);
        assertEq(usdg.balanceOf(merchant), U);
    }

    function test_incidentReportedOnAutoRevoke() public {
        (, MockIncidentRegistry registry) = _incidentSetup(42);
        vm.prank(owner);
        leash.setMaxStrikes(1);

        vm.recordLogs();
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_eventExists(logs, keccak256("IncidentReported(address,uint256,bool)")));
        assertEq(registry.lastIndex(42, address(leash)), 1);
        assertFalse(registry.policyActiveDuringCall());
        (bool active,,,,,) = leash.policies(agent);
        assertFalse(active);

        address[] memory clients = new address[](1);
        clients[0] = address(leash);
        (uint64 count, int128 value, uint8 decimals) = registry.getSummary(42, clients, "leash", "auto-revoked");
        assertEq(count, 1);
        assertEq(value, -100);
        assertEq(decimals, 0);
    }

    function test_incidentNotReportedWhenUnconfigured() public {
        vm.prank(owner);
        leash.setMaxStrikes(1);
        vm.recordLogs();
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_eventExists(logs, keccak256("IncidentReported(address,uint256,bool)")));
        assertFalse(_eventExists(logs, keccak256("IncidentReportFailed(address,uint256)")));
        assertFalse(_policyIsActive(agent));
    }

    function test_zeroFeedbackRegistryDisablesReporting() public {
        (, MockIncidentRegistry registry) = _incidentSetup(42);
        vm.startPrank(owner);
        leash.setFeedbackRegistry(address(0));
        leash.setMaxStrikes(1);
        vm.stopPrank();

        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        assertEq(registry.lastIndex(42, address(leash)), 0);
        assertFalse(_eventExists(vm.getRecordedLogs(), keccak256("IncidentReported(address,uint256,bool)")));
    }

    function test_incidentNotReportedWhenUnlinked() public {
        MockIncidentIdentity identity = new MockIncidentIdentity();
        identity.mint(42, agent);
        MockIncidentRegistry registry = new MockIncidentRegistry(address(identity));
        vm.startPrank(owner);
        leash.setFeedbackRegistry(address(registry));
        leash.setMaxStrikes(1);
        vm.stopPrank();

        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        assertEq(registry.lastIndex(42, address(leash)), 0);
        assertFalse(leash.agentIdLinked(agent));
    }

    function test_incidentRegistryRevertDoesNotPreventRevocation() public {
        (, MockIncidentRegistry registry) = _incidentSetup(42);
        registry.setBehavior(true, false);
        vm.prank(owner);
        leash.setMaxStrikes(1);

        vm.recordLogs();
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_eventExists(logs, keccak256("IncidentReportFailed(address,uint256)")));
        assertFalse(_policyIsActive(agent));
    }

    function test_incidentRegistryGasExhaustionDoesNotPreventRevocation() public {
        (, MockIncidentRegistry registry) = _incidentSetup(42);
        registry.setBehavior(false, true);
        vm.prank(owner);
        leash.setMaxStrikes(1);

        vm.recordLogs();
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_eventExists(logs, keccak256("IncidentReportFailed(address,uint256)")));
        assertFalse(_policyIsActive(agent));
    }

    function test_linkAgentIdRejectsIdNotOwnedByAgent() public {
        MockIncidentIdentity identity = new MockIncidentIdentity();
        identity.mint(42, stranger);
        MockIncidentRegistry registry = new MockIncidentRegistry(address(identity));
        vm.prank(owner);
        leash.setFeedbackRegistry(address(registry));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Leash.AgentIdOwnerMismatch.selector, agent, stranger));
        leash.linkAgentId(agent, 42);
        assertFalse(leash.agentIdLinked(agent));
    }

    function test_feedbackRegistryAndLinkRequireOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        leash.setFeedbackRegistry(address(1));
        vm.prank(attacker);
        vm.expectRevert();
        leash.linkAgentId(agent, 42);
    }

    function test_strikesBelowLimitDoNotWriteFeedback() public {
        (, MockIncidentRegistry registry) = _incidentSetup(42);
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        assertEq(leash.strikes(agent), 1);
        assertEq(registry.lastIndex(42, address(leash)), 0);
        assertTrue(_policyIsActive(agent));
    }

    function test_incidentFeedbackHashDiffersPerIncident() public {
        (, MockIncidentRegistry registry) = _incidentSetup(42);
        vm.prank(owner);
        leash.setMaxStrikes(1);
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        (,,,, bytes32 firstHash) = registry.readFeedback(42, address(leash), 1);

        vm.startPrank(owner);
        leash.resetStrikes(agent);
        leash.setPolicy(agent, _policy(10 * U, 25 * U, 5 * U, 0));
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        (,,,, bytes32 secondHash) = registry.readFeedback(42, address(leash), 2);
        assertTrue(firstHash != secondHash);
    }

    function test_incidentMockRejectsOwnerSelfFeedback() public {
        MockIncidentIdentity identity = new MockIncidentIdentity();
        identity.mint(42, agent);
        MockIncidentRegistry registry = new MockIncidentRegistry(address(identity));
        vm.prank(agent);
        vm.expectRevert(bytes("Self-feedback not allowed"));
        registry.giveFeedback(42, -100, 0, "leash", "auto-revoked", "", "", bytes32(uint256(1)));
    }

    function test_incidentMockRejectsApprovedOperatorAndRevocationStillSucceeds() public {
        (MockIncidentIdentity identity, MockIncidentRegistry registry) = _incidentSetup(42);
        vm.prank(agent);
        identity.setApprovalForAll(address(leash), true);
        vm.prank(owner);
        leash.setMaxStrikes(1);

        vm.recordLogs();
        vm.prank(agent);
        assertFalse(leash.tryPay(agent, stranger, U));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_eventExists(logs, keccak256("IncidentReportFailed(address,uint256)")));
        assertEq(registry.lastIndex(42, address(leash)), 0);
        assertFalse(_policyIsActive(agent));
    }

    // ------------------------------------------------------- reputation gating
    function test_reputation_allowsTrustedUnlisted() public {
        vm.startPrank(owner);
        leash.setPolicy(agent, _policy(10 * U, 25 * U, 5 * U, 70));
        vm.stopPrank();
        rep.set(stranger, 80);
        vm.prank(agent);
        leash.pay(stranger, 2 * U, "");
        assertEq(usdg.balanceOf(stranger), 2 * U);
    }

    function test_reputation_blocksLowScore() public {
        vm.prank(owner);
        leash.setPolicy(agent, _policy(10 * U, 25 * U, 5 * U, 70));
        rep.set(stranger, 69);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Leash.TrustTooLow.selector, 69, 70));
        leash.pay(stranger, 1 * U, "");
    }

    function test_reputation_failsClosedIfSourceReverts() public {
        vm.prank(owner);
        leash.setPolicy(agent, _policy(10 * U, 25 * U, 5 * U, 70));
        rep.set(stranger, 99);
        rep.setBroken(true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Leash.TrustUnavailable.selector, stranger));
        leash.pay(stranger, 1 * U, "");
    }

    function test_reputation_ignoredWhenMinTrustZero() public {
        rep.set(stranger, 100);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Leash.NotAllowlisted.selector, stranger));
        leash.pay(stranger, 1 * U, "");
    }

    // ------------------------------------------------------------ approval flow
    function test_approval_largePaymentPendsThenExecutes() public {
        vm.prank(agent);
        uint256 id = leash.pay(merchant, 8 * U, "big"); // > 5 threshold
        assertEq(id, 1);
        assertEq(usdg.balanceOf(merchant), 0);

        vm.prank(owner);
        leash.approve(id);
        assertEq(usdg.balanceOf(merchant), 8 * U);
        assertEq(leash.windowSpent(agent), 8 * U);
    }

    function test_approval_revokedAgentRequestCannotExecute() public {
        vm.prank(agent);
        uint256 id = leash.pay(merchant, 8 * U, "big");
        vm.startPrank(owner);
        leash.revoke(agent);
        vm.expectRevert(Leash.NotAgent.selector);
        leash.approve(id);
        vm.stopPrank();
    }

    function test_approval_expires() public {
        vm.prank(agent);
        uint256 id = leash.pay(merchant, 8 * U, "big");
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner);
        vm.expectRevert(Leash.RequestExpired.selector);
        leash.approve(id);
    }

    function test_approval_cannotDoubleExecute() public {
        vm.prank(agent);
        uint256 id = leash.pay(merchant, 8 * U, "big");
        vm.startPrank(owner);
        leash.approve(id);
        vm.expectRevert(Leash.BadRequest.selector);
        leash.approve(id);
        vm.stopPrank();
    }

    function test_approval_rejectByOwnerOrAgentOnly() public {
        vm.prank(agent);
        uint256 id = leash.pay(merchant, 8 * U, "big");
        vm.prank(attacker);
        vm.expectRevert(Leash.BadRequest.selector);
        leash.reject(id);
        vm.prank(agent);
        leash.reject(id);
        vm.prank(owner);
        vm.expectRevert(Leash.BadRequest.selector);
        leash.approve(id);
    }

    function test_approval_onlyOwner() public {
        vm.prank(agent);
        uint256 id = leash.pay(merchant, 8 * U, "big");
        vm.prank(agent);
        vm.expectRevert();
        leash.approve(id); // agent cannot self-approve
    }

    function test_approval_stillRespectsWindowCap() public {
        vm.startPrank(agent);
        for (uint256 i; i < 4; i++) leash.pay(merchant, 5 * U, ""); // 20
        uint256 id = leash.pay(merchant, 8 * U, "big"); // pending, would be 28 > 25
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Leash.WindowCapExceeded.selector, 20 * U, 8 * U, 25 * U));
        leash.approve(id);
    }

    // --------------------------------------------------------------- admin
    function test_setPolicy_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(Leash.InvalidPolicy.selector);
        leash.setPolicy(address(0), _policy(1, 1, 1, 0));
        vm.expectRevert(Leash.InvalidPolicy.selector);
        leash.setPolicy(agent, _policy(0, 1, 1, 0));
        vm.expectRevert(Leash.InvalidPolicy.selector);
        leash.setPolicy(agent, _policy(10, 5, 1, 0)); // window < perTx
        vm.expectRevert(Leash.InvalidPolicy.selector);
        leash.setPolicy(agent, _policy(10, 10, 1, 101));
        vm.stopPrank();
    }

    function test_onlyOwnerAdmin() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        leash.setPolicy(attacker, _policy(1e9, 1e9, 1e9, 0));
        vm.expectRevert();
        leash.withdraw(attacker, 1);
        vm.expectRevert();
        leash.setAllowed(attacker, true);
        vm.expectRevert();
        leash.pause();
        vm.stopPrank();
    }

    function test_ownerWithdraw() public {
        vm.prank(owner);
        leash.withdraw(owner, 100 * U);
        assertEq(usdg.balanceOf(owner), 100 * U);
    }

    function test_checkPaymentDryRun() public {
        assertEq(leash.checkPayment(agent, merchant, 1 * U), "");
        assertEq(leash.checkPayment(agent, stranger, 1 * U), "NOT_ALLOWLISTED");
        assertEq(leash.checkPayment(agent, merchant, 11 * U), "PER_TX_CAP");
        assertEq(leash.checkPayment(attacker, merchant, 1 * U), "NOT_AGENT");
    }

    // ------------------------------------------------------ ERC-8004 adapter
    function _adapterSetup() internal returns (MockERC8004Registry reg, ERC8004ReputationAdapter ad, address reviewer) {
        MockIdentity idr = new MockIdentity();
        reg = new MockERC8004Registry(address(idr));
        ad = new ERC8004ReputationAdapter(address(reg), 3, owner);
        reviewer = makeAddr("reviewer");
        idr.mint(42, stranger);
        vm.startPrank(owner);
        ad.link(stranger, 42);
        ad.setTrustedClient(reviewer, true);
        vm.stopPrank();
    }

    function test_adapter_neverCallsRegistryWithEmptyClientList() public {
        MockIdentity idr = new MockIdentity();
        MockERC8004Registry reg = new MockERC8004Registry(address(idr));
        ERC8004ReputationAdapter ad = new ERC8004ReputationAdapter(address(reg), 1, owner);
        idr.mint(7, stranger);
        vm.prank(owner);
        ad.link(stranger, 7);
        // no trusted clients configured: must return 0, NOT revert like the real registry would
        assertEq(ad.trustScore(stranger), 0);
    }

    function test_adapter_scoreFromTrustedReviewersOnly() public {
        (MockERC8004Registry reg, ERC8004ReputationAdapter ad, address reviewer) = _adapterSetup();
        address sybil = makeAddr("sybil");
        assertEq(ad.trustScore(stranger), 0); // no feedback
        reg.setFeedback(42, reviewer, 2, 90, 0);
        assertEq(ad.trustScore(stranger), 0); // below min count
        reg.setFeedback(42, reviewer, 5, 8_750, 2); // 87.50 -> 87
        assertEq(ad.trustScore(stranger), 87);
        reg.setFeedback(42, sybil, 1000, 100, 0); // untrusted spam is ignored
        assertEq(ad.trustScore(stranger), 87);
        reg.setFeedback(42, reviewer, 5, 500, 0); // clamps to 100
        assertEq(ad.trustScore(stranger), 100);
        reg.setFeedback(42, reviewer, 5, -10, 0);
        assertEq(ad.trustScore(stranger), 0);
        assertEq(ad.trustScore(attacker), 0); // unlinked
    }

    function test_adapter_linkRequiresExistingAgentId() public {
        (, ERC8004ReputationAdapter ad,) = _adapterSetup();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC8004ReputationAdapter.UnknownAgentId.selector, 999));
        ad.link(stranger, 999);
    }

    function test_adapter_clientListAdminAndBounds() public {
        (, ERC8004ReputationAdapter ad, address reviewer) = _adapterSetup();
        vm.startPrank(owner);
        ad.setTrustedClient(reviewer, false);
        assertEq(ad.trustedClients().length, 0);
        for (uint256 i; i < 20; i++) ad.setTrustedClient(address(uint160(1000 + i)), true);
        vm.expectRevert(ERC8004ReputationAdapter.TooManyClients.selector);
        ad.setTrustedClient(address(uint160(5000)), true);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert();
        ad.setTrustedClient(attacker, true);
    }

    function test_adapter_endToEndWithLeash() public {
        (MockERC8004Registry reg, ERC8004ReputationAdapter ad, address reviewer) = _adapterSetup();
        vm.startPrank(owner);
        ad.setMinFeedbackCount(1);
        leash.setReputationSource(address(ad));
        leash.setPolicy(agent, _policy(10 * U, 25 * U, 5 * U, 60));
        vm.stopPrank();
        reg.setFeedback(42, reviewer, 10, 85, 0);

        vm.prank(agent);
        leash.pay(stranger, 1 * U, "");
        assertEq(usdg.balanceOf(stranger), 1 * U);

        reg.setFeedback(42, reviewer, 10, 20, 0); // reputation collapses -> blocked
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Leash.TrustTooLow.selector, 20, 60));
        leash.pay(stranger, 1 * U, "");
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_neverExceedsWindowCapAcrossTime(uint8[24] calldata amts, uint16[24] calldata gaps) public {
        uint256 cap = leash.remainingAllowance(agent);
        uint256 total;
        uint256[] memory times = new uint256[](24);
        uint256[] memory paid = new uint256[](24);
        uint256 n;
        for (uint256 i; i < 24; i++) {
            vm.warp(block.timestamp + uint256(gaps[i]) * 20); // up to ~3.6h per step
            uint256 a = (uint256(amts[i]) % 5 + 1) * U; // 1..5 USDG (<= approval threshold)
            vm.prank(agent);
            try leash.pay(merchant, a, "") {
                times[n] = block.timestamp;
                paid[n] = a;
                n++;
            } catch {}
            // check every trailing 24h window ending now
            total = 0;
            for (uint256 j; j < n; j++) {
                if (times[j] + 24 hours >= block.timestamp) total += paid[j];
            }
            assertLe(total, cap);
        }
    }
}
