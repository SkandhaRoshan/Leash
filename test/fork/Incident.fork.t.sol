// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Leash} from "../../src/Leash.sol";
import {IERC8004Reputation, IERC721Owner} from "../../src/adapters/ERC8004ReputationAdapter.sol";
import {MockUSDG} from "../mocks/Mocks.sol";

contract IncidentForkTest is Test {
    address constant REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant ATTACKER = 0x000000000000000000000000000000000000bEEF;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_ONE_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
    }

    function test_autoRevocationWritesLiveNegativeFeedback() public {
        (uint256 agentId, address agent) = _findEoaOwnedAgentId();
        emit log_named_uint("Dynamically discovered ERC-8004 agentId", agentId);
        emit log_named_address("Agent EOA owner", agent);

        MockUSDG token = new MockUSDG();
        Leash leash = new Leash(address(token), address(this));
        leash.setFeedbackRegistry(REPUTATION);
        leash.linkAgentId(agent, agentId);
        leash.setMaxStrikes(1);
        leash.setPolicy(
            agent,
            Leash.Policy({
                active: true,
                expiry: uint64(block.timestamp + 1 days),
                perTxCap: 10,
                windowCap: 20,
                approvalThreshold: 10,
                minTrust: 0
            })
        );

        vm.prank(agent);
        assertFalse(leash.tryPay(agent, ATTACKER, 1));
        assertEq(leash.strikes(agent), 1);
        (bool active,,,,,) = leash.policies(agent);
        assertFalse(active, "agent policy must be revoked");

        address[] memory clients = new address[](1);
        clients[0] = address(leash);
        (uint64 count, int128 summaryValue, uint8 decimals) = IERC8004Reputation(REPUTATION).getSummary(
            agentId, clients, "leash", "auto-revoked"
        );
        assertEq(count, 1, "live registry must include the incident");
        assertLt(summaryValue, 0, "incident feedback must be negative");
        assertEq(decimals, 0);
    }

    function _findEoaOwnedAgentId() internal view returns (uint256 foundId, address foundOwner) {
        IERC721Owner identity = IERC721Owner(IDENTITY);
        for (uint256 agentId = 1; agentId <= 10_000; agentId++) {
            try identity.ownerOf(agentId) returns (address candidate) {
                if (candidate != address(0) && candidate.code.length == 0) return (agentId, candidate);
            } catch {}
        }
        revert("No EOA-owned ERC-8004 agent found in scan");
    }
}
