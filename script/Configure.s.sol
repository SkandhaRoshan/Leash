// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Leash} from "../src/Leash.sol";

interface ITrustedReviewerAdmin {
    function owner() external view returns (address);
    function setTrustedClient(address client, bool trusted) external;
}

/// Owner-checked, environment-driven post-deployment configuration.
/// Run without --broadcast to simulate all changes on a local node or fork.
contract Configure is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        address leashAddress = vm.envAddress("LEASH");
        address registry = vm.envOr("FEEDBACK_REGISTRY", address(0));
        uint256 maxStrikes = vm.envOr("MAX_STRIKES", uint256(3));
        address adapter = vm.envOr("REPUTATION_ADAPTER", address(0));
        uint256 allowlistCount = vm.envOr("ALLOWLIST_COUNT", uint256(0));
        uint256 linkCount = vm.envOr("LINK_COUNT", uint256(0));
        uint256 reviewerCount = vm.envOr("TRUSTED_REVIEWER_COUNT", uint256(0));

        require(block.chainid == expectedChainId, "Configure: unexpected chain id");
        require(leashAddress.code.length > 0, "Configure: LEASH has no code");
        Leash leash = Leash(leashAddress);
        require(leash.owner() == signer, "Configure: PRIVATE_KEY must own Leash");
        require(maxStrikes >= 1 && maxStrikes <= 10, "Configure: MAX_STRIKES out of bounds");
        require(registry == address(0) || registry.code.length > 0, "Configure: registry has no code");
        require(registry != address(0) || linkCount == 0, "Configure: links require FEEDBACK_REGISTRY");

        if (reviewerCount > 0) {
            require(adapter != address(0) && adapter.code.length > 0, "Configure: reviewers require adapter");
            require(ITrustedReviewerAdmin(adapter).owner() == signer, "Configure: PRIVATE_KEY must own adapter");
        }

        console.log("Configure simulation chain id:", block.chainid);
        console.log("Leash:", leashAddress);
        console.log("Owner signer:", signer);
        console.log("Feedback registry:", registry);
        console.log("Max strikes:", maxStrikes);
        console.log("Allowlist entries:", allowlistCount);
        console.log("Agent identity links:", linkCount);
        console.log("Trusted reviewers:", reviewerCount);

        vm.startBroadcast(privateKey);
        leash.setFeedbackRegistry(registry);
        leash.setMaxStrikes(maxStrikes);

        for (uint256 i; i < allowlistCount; i++) {
            address account = vm.envAddress(string.concat("ALLOWLIST_", vm.toString(i)));
            leash.setAllowed(account, true);
            console.log("Allowlisted:", account);
        }

        for (uint256 i; i < linkCount; i++) {
            address agent = vm.envAddress(string.concat("LINK_AGENT_", vm.toString(i)));
            uint256 agentId = vm.envUint(string.concat("LINK_AGENT_ID_", vm.toString(i)));
            leash.linkAgentId(agent, agentId);
            console.log("Linked agent:", agent, "agentId:", agentId);
        }

        for (uint256 i; i < reviewerCount; i++) {
            address reviewer = vm.envAddress(string.concat("TRUSTED_REVIEWER_", vm.toString(i)));
            ITrustedReviewerAdmin(adapter).setTrustedClient(reviewer, true);
            console.log("Trusted reviewer:", reviewer);
        }
        vm.stopBroadcast();
        console.log("Configuration simulation complete. No changes are broadcast unless --broadcast is supplied.");
    }
}
