// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC8004ReputationAdapter, IERC8004Reputation, IERC721Owner} from "../../src/adapters/ERC8004ReputationAdapter.sol";

/// Runs against the REAL ERC-8004 registries on Arbitrum One. Skipped unless ARBITRUM_ONE_RPC is set:
///   ARBITRUM_ONE_RPC=https://arb1.arbitrum.io/rpc forge test --match-path test/fork/* -vv
/// If any of these fail, the adapter's assumptions about the live registry are wrong: fix before mainnet.
contract ERC8004ForkTest is Test {
    address constant REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address admin = makeAddr("admin");
    address reviewer = makeAddr("reviewer");

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_ONE_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
    }

    function test_registriesAreDeployed() public view {
        assertGt(REPUTATION.code.length, 0, "no reputation registry");
        assertGt(IDENTITY.code.length, 0, "no identity registry");
    }

    function test_reputationPointsAtIdentity() public view {
        assertEq(IERC8004Reputation(REPUTATION).getIdentityRegistry(), IDENTITY);
    }

    /// The assumption that caused a real bug: the live registry rejects an empty reviewer list.
    function test_getSummary_emptyClientListReverts() public {
        vm.expectRevert();
        IERC8004Reputation(REPUTATION).getSummary(1, new address[](0), "", "");
    }

    function test_getSummary_nonEmptyListWorks() public view {
        address[] memory c = new address[](1);
        c[0] = reviewer;
        (uint64 count,, uint8 dec) = IERC8004Reputation(REPUTATION).getSummary(1, c, "", "");
        assertEq(count, 0); // random reviewer has left no feedback
        assertLe(dec, 18);
    }

    function test_adapter_linksRealAgentAndScoresWithoutReverting() public {
        address agentOwner = IERC721Owner(IDENTITY).ownerOf(1); // agentId 1 should exist on mainnet
        ERC8004ReputationAdapter ad = new ERC8004ReputationAdapter(REPUTATION, 1, admin);
        vm.startPrank(admin);
        ad.link(agentOwner, 1);
        ad.setTrustedClient(reviewer, true);
        vm.stopPrank();
        assertEq(ad.trustScore(agentOwner), 0); // must not revert against the real registry
    }

    function test_adapter_rejectsNonexistentAgentId() public {
        ERC8004ReputationAdapter ad = new ERC8004ReputationAdapter(REPUTATION, 1, admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ERC8004ReputationAdapter.UnknownAgentId.selector, type(uint256).max));
        ad.link(reviewer, type(uint256).max);
    }
}
