// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Leash} from "../src/Leash.sol";
import {MockUSDG} from "../test/mocks/Mocks.sol";

/// LOCAL ANVIL ONLY (used by demo.sh). Refuses to run on any real network.
contract LocalDev is Script {
    function run() external {
        require(block.chainid == 31337, "LocalDev is for anvil (chainid 31337) only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        MockUSDG m = new MockUSDG();
        m.mint(deployer, 1_000e6);
        Leash leash = new Leash(address(m), deployer);
        vm.stopBroadcast();
        console.log("Leash:", address(leash));
        console.log("Token:", address(m));
    }
}
