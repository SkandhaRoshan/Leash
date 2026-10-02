// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Leash} from "../src/Leash.sol";
import {MockUSDG} from "./mocks/Mocks.sol";

/// @dev Drives random agent payments, owner approvals and time jumps, and records every
///      successful outflow so the invariants can be checked against ground truth.
contract Handler is Test {
    Leash public leash;
    MockUSDG public usdg;
    address public agent;
    address public owner;
    address[] public merchants;

    uint256[] public times;
    uint256[] public amounts;
    uint256 public totalPaid;
    uint256 public maxWindowSeen;
    bool public capViolated;
    uint256 public cap;

    constructor(Leash l, MockUSDG u, address a, address o, address[] memory m, uint256 cap_) {
        leash = l;
        usdg = u;
        agent = a;
        owner = o;
        merchants = m;
        cap = cap_;
    }

    function pay(uint256 amt, uint256 mSeed) external {
        amt = bound(amt, 1, 12e6);
        address m = merchants[mSeed % merchants.length];
        vm.prank(agent);
        try leash.pay(m, amt, "") returns (uint256 id) {
            if (id == 0) _record(amt);
        } catch {}
    }

    function approvePending(uint256 id) external {
        id = bound(id, 1, leash.nextRequestId());
        (,, uint128 amount,,,) = leash.requests(id);
        vm.prank(owner);
        try leash.approve(id) {
            _record(amount);
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 6 hours));
    }

    function _record(uint256 amt) internal {
        times.push(block.timestamp);
        amounts.push(amt);
        totalPaid += amt;
        uint256 w;
        for (uint256 i; i < times.length; i++) {
            if (times[i] + 24 hours >= block.timestamp) w += amounts[i];
        }
        if (w > maxWindowSeen) maxWindowSeen = w;
        if (w > cap) capViolated = true;
    }
}

contract LeashInvariantTest is Test {
    Leash leash;
    MockUSDG usdg;
    Handler handler;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    uint256 constant FUNDED = 10_000e6;
    uint256 constant CAP = 40e6;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockUSDG();
        leash = new Leash(address(usdg), owner);
        usdg.mint(address(leash), FUNDED);

        address[] memory ms = new address[](3);
        for (uint256 i; i < 3; i++) ms[i] = makeAddr(string.concat("m", vm.toString(i)));

        vm.startPrank(owner);
        for (uint256 i; i < 3; i++) leash.setAllowed(ms[i], true);
        leash.setPolicy(
            agent,
            Leash.Policy({
                active: true,
                expiry: type(uint64).max,
                perTxCap: 10e6,
                windowCap: uint128(CAP),
                approvalThreshold: 6e6,
                minTrust: 0
            })
        );
        vm.stopPrank();

        handler = new Handler(leash, usdg, agent, owner, ms, CAP);
        targetContract(address(handler));
    }

    /// The headline guarantee: in ANY trailing 24h window, outflow <= windowCap.
    function invariant_agentNeverExceedsWindowCap() public view {
        assertFalse(handler.capViolated());
        assertLe(handler.maxWindowSeen(), CAP);
    }

    /// Accounting: every token that left the vault is a recorded, policy-checked payment.
    function invariant_vaultBalanceMatchesRecordedPayments() public view {
        assertEq(usdg.balanceOf(address(leash)) + handler.totalPaid(), FUNDED);
    }

    /// Contract's own view of the window never exceeds the cap either.
    function invariant_onChainWindowWithinCap() public view {
        assertLe(leash.windowSpent(agent), CAP);
    }
}
