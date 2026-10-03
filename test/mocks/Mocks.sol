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

contract MockIncidentIdentity {
    mapping(uint256 => address) public owners;
    mapping(uint256 => address) public approved;
    mapping(address => mapping(address => bool)) public operators;

    function mint(uint256 id, address to) external {
        owners[id] = to;
    }

    function ownerOf(uint256 id) public view returns (address) {
        require(owners[id] != address(0), "ERC721NonexistentToken");
        return owners[id];
    }

    function approve(uint256 id, address operator) external {
        require(msg.sender == ownerOf(id), "not token owner");
        approved[id] = operator;
    }

    function setApprovalForAll(address operator, bool isApproved) external {
        operators[msg.sender][operator] = isApproved;
    }

    function isAuthorizedOrOwner(address spender, uint256 id) external view returns (bool) {
        address tokenOwner = ownerOf(id);
        return spender == tokenOwner || approved[id] == spender || operators[tokenOwner][spender];
    }
}

interface IIncidentPolicyReader {
    function policies(address agent)
        external
        view
        returns (bool active, uint64 expiry, uint128 perTxCap, uint128 windowCap, uint128 approvalThreshold, uint8 minTrust);
}

contract MockIncidentRegistry {
    struct Feedback {
        int128 value;
        uint8 decimals;
        string tag1;
        string tag2;
        bytes32 feedbackHash;
    }

    address public immutable identity;
    bool public shouldRevert;
    bool public consumeGas;
    bool public policyActiveDuringCall;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    address public callbackAgent;
    address public callbackTo;
    address public callbackTarget;
    bytes public callbackData;
    mapping(uint256 => mapping(address => uint64)) public lastIndex;
    mapping(uint256 => mapping(address => mapping(uint64 => Feedback))) private _feedback;

    constructor(address identity_) {
        identity = identity_;
    }

    function setBehavior(bool shouldRevert_, bool consumeGas_) external {
        shouldRevert = shouldRevert_;
        consumeGas = consumeGas_;
    }

    function setCallback(address agent, address to) external {
        callbackAgent = agent;
        callbackTo = to;
    }

    function setCallbackData(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function execute(address target, bytes calldata data) external returns (bool success) {
        (success,) = target.call(data);
    }

    function getIdentityRegistry() external view returns (address) {
        return identity;
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata,
        string calldata,
        bytes32 feedbackHash
    ) external {
        if (consumeGas) {
            while (gasleft() > 0) {}
        }
        require(!shouldRevert, "mock feedback failure");
        _storeFeedback(agentId, value, valueDecimals, tag1, tag2, feedbackHash);
        if (callbackTarget != address(0)) {
            callbackAttempted = true;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
        } else if (callbackAgent != address(0)) {
            callbackAttempted = true;
            (callbackSucceeded,) = msg.sender.call(
                abi.encodeWithSignature("tryPay(address,address,uint256)", callbackAgent, callbackTo, 1)
            );
        }
    }

    function _storeFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        bytes32 feedbackHash
    ) private {
        MockIncidentIdentity idRegistry = MockIncidentIdentity(identity);
        require(!idRegistry.isAuthorizedOrOwner(msg.sender, agentId), "Self-feedback not allowed");
        (policyActiveDuringCall,,,,,) = IIncidentPolicyReader(msg.sender).policies(idRegistry.ownerOf(agentId));

        uint64 index = lastIndex[agentId][msg.sender] + 1;
        lastIndex[agentId][msg.sender] = index;
        _feedback[agentId][msg.sender][index] = Feedback(value, valueDecimals, tag1, tag2, feedbackHash);
    }

    function readFeedback(uint256 agentId, address client, uint64 index)
        external
        view
        returns (int128 value, uint8 decimals, string memory tag1, string memory tag2, bytes32 feedbackHash)
    {
        Feedback storage feedback = _feedback[agentId][client][index];
        return (feedback.value, feedback.decimals, feedback.tag1, feedback.tag2, feedback.feedbackHash);
    }

    function getSummary(uint256 agentId, address[] calldata clients, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals)
    {
        require(clients.length > 0, "clientAddresses required");
        summaryValueDecimals = 0;
        int256 sum;
        for (uint256 i; i < clients.length; i++) {
            for (uint64 index = 1; index <= lastIndex[agentId][clients[i]]; index++) {
                Feedback storage feedback = _feedback[agentId][clients[i]][index];
                if (bytes(tag1).length != 0 && keccak256(bytes(tag1)) != keccak256(bytes(feedback.tag1))) continue;
                if (bytes(tag2).length != 0 && keccak256(bytes(tag2)) != keccak256(bytes(feedback.tag2))) continue;
                sum += feedback.value;
                count++;
            }
        }
        if (count > 0) summaryValue = int128(sum / int256(uint256(count)));
    }
}
