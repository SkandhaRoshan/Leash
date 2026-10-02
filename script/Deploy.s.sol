// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Leash} from "../src/Leash.sol";
import {ERC8004ReputationAdapter} from "../src/adapters/ERC8004ReputationAdapter.sol";

/// PRODUCTION deploy. No mocks: TOKEN must be a real, already-deployed ERC-20.
///   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --verify
/// Env: PRIVATE_KEY, TOKEN (required),
///      ERC8004_REPUTATION_REGISTRY (optional; Arbitrum One: 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63),
///      MIN_FEEDBACK (optional, default 3)
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address token = vm.envAddress("TOKEN");
        address registry = vm.envOr("ERC8004_REPUTATION_REGISTRY", address(0));
        uint64 minFeedback = uint64(vm.envOr("MIN_FEEDBACK", uint256(3)));

        require(token.code.length > 0, "TOKEN has no code on this chain");
        require(registry == address(0) || registry.code.length > 0, "registry has no code on this chain");

        vm.startBroadcast(pk);
        Leash leash = new Leash(token, deployer);
        address adapter;
        if (registry != address(0)) {
            adapter = address(new ERC8004ReputationAdapter(registry, minFeedback, deployer));
            leash.setReputationSource(adapter);
        }
        vm.stopBroadcast();

        console.log("chainid:", block.chainid);
        console.log("Leash:", address(leash));
        console.log("Owner:", deployer);
        console.log("Token:", token);
        console.log("ReputationAdapter:", adapter);
    }
}
