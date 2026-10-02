// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Leash} from "../src/Leash.sol";
import {ERC8004ReputationAdapter} from "../src/adapters/ERC8004ReputationAdapter.sol";
import {MockUSDG, MockReputation, MockERC8004Registry, MockIdentity} from "./mocks/Mocks.sol";

contract LeashTest is Test {
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
