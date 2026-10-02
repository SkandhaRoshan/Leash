// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IReputationSource} from "../../src/interfaces/IReputationSource.sol";

contract MockUSDG is ERC20 {
    constructor() ERC20("Mock USDG", "mUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockReputation is IReputationSource {
    mapping(address => uint256) public scores;
    bool public broken;

    function set(address a, uint256 s) external {
        scores[a] = s;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function trustScore(address a) external view returns (uint256) {
        require(!broken, "broken");
        return scores[a];
    }
}

/// @dev Mirrors the REAL ERC-8004 behaviour we depend on: getSummary reverts on an empty
///      clientAddresses list, and only counts feedback from the listed clients.
contract MockERC8004Registry {
    struct S {
        uint64 count;
        int128 value;
        uint8 decimals;
    }
    mapping(uint256 => mapping(address => S)) public byClient; // agentId => client => aggregate
    address public identity;

    constructor(address identity_) {
        identity = identity_;
    }

    function getIdentityRegistry() external view returns (address) {
        return identity;
    }

    function setFeedback(uint256 id, address client, uint64 count, int128 value, uint8 decimals) external {
        byClient[id][client] = S(count, value, decimals);
    }

    function getSummary(uint256 id, address[] calldata clients, string calldata, string calldata)
        external
        view
        returns (uint64 count, int128 value, uint8 decimals)
    {
        require(clients.length > 0, "clientAddresses required");
        for (uint256 i; i < clients.length; i++) {
            S memory s = byClient[id][clients[i]];
            count += s.count;
            value += s.value * int128(uint128(s.count)); // weighted by count
            if (s.count > 0) decimals = s.decimals;
        }
        if (count > 0) value = value / int128(uint128(count)); // average
    }
}

contract MockIdentity {
    mapping(uint256 => address) public owners;

    function mint(uint256 id, address to) external {
        owners[id] = to;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(owners[id] != address(0), "nonexistent token");
        return owners[id];
    }
}
