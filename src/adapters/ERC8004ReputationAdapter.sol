// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReputationSource} from "../interfaces/IReputationSource.sol";

/// @dev Subset of the ERC-8004 Reputation Registry (spec: eips.ethereum.org/EIPS/eip-8004).
///      The official implementation REQUIRES a non-empty `clientAddresses` in getSummary
///      (anti-Sybil), so this adapter only ever passes a curated, non-empty reviewer list.
interface IERC8004Reputation {
    function getIdentityRegistry() external view returns (address);

    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);
}

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Turns ERC-8004 feedback into Leash's 0..100 trust score, counting ONLY feedback
///         from reviewers the admin trusts. Open-registry feedback is Sybil-able, so an
///         agent's score here is only as good as the reviewer list you curate.
///         Feedback values are assumed to use a 0..100 scale for the configured tags.
contract ERC8004ReputationAdapter is IReputationSource, Ownable {
    uint256 public constant MAX_CLIENTS = 20; // bounds gas of the registry call

    IERC8004Reputation public immutable registry;
    uint64 public minFeedbackCount;
    string public tag1;
    string public tag2;
    address[] private _trustedClients;
    mapping(address => bool) public isTrustedClient;

    mapping(address => uint256) public agentIdOf;
    mapping(address => bool) public isLinked;

    event AgentLinked(address indexed counterparty, uint256 indexed agentId);
    event AgentUnlinked(address indexed counterparty);
    event ClientTrusted(address indexed client, bool trusted);
    event TagsSet(string tag1, string tag2);
    event MinFeedbackCountSet(uint64 n);

    error ZeroAddress();
    error TooManyClients();
    error UnknownAgentId(uint256 agentId);

    constructor(address registry_, uint64 minFeedbackCount_, address admin) Ownable(admin) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = IERC8004Reputation(registry_);
        minFeedbackCount = minFeedbackCount_;
    }

    // ------------------------------------------------------------------ admin
    /// @notice Link a payee address to its ERC-8004 agentId. Reverts if the agentId does not
    ///         exist in the Identity Registry. NOTE: the payee<->agentId binding is an admin
    ///         attestation; the registry cannot be reverse-looked-up from an address.
    function link(address counterparty, uint256 agentId) external onlyOwner {
        if (counterparty == address(0)) revert ZeroAddress();
        try IERC721Owner(registry.getIdentityRegistry()).ownerOf(agentId) returns (address) {}
        catch {
            revert UnknownAgentId(agentId);
        }
        agentIdOf[counterparty] = agentId;
        isLinked[counterparty] = true;
        emit AgentLinked(counterparty, agentId);
    }

    function unlink(address counterparty) external onlyOwner {
        delete agentIdOf[counterparty];
        isLinked[counterparty] = false;
        emit AgentUnlinked(counterparty);
    }

    function setTrustedClient(address client, bool trusted) external onlyOwner {
        if (client == address(0)) revert ZeroAddress();
        if (trusted == isTrustedClient[client]) return;
        isTrustedClient[client] = trusted;
        if (trusted) {
            if (_trustedClients.length >= MAX_CLIENTS) revert TooManyClients();
            _trustedClients.push(client);
        } else {
            uint256 n = _trustedClients.length;
            for (uint256 i; i < n; i++) {
                if (_trustedClients[i] == client) {
                    _trustedClients[i] = _trustedClients[n - 1];
                    _trustedClients.pop();
                    break;
                }
            }
        }
        emit ClientTrusted(client, trusted);
    }

    function setTags(string calldata t1, string calldata t2) external onlyOwner {
        tag1 = t1;
        tag2 = t2;
        emit TagsSet(t1, t2);
    }

    function setMinFeedbackCount(uint64 n) external onlyOwner {
        minFeedbackCount = n;
        emit MinFeedbackCountSet(n);
    }

    // ------------------------------------------------------------------ views
    function trustedClients() external view returns (address[] memory) {
        return _trustedClients;
    }

    /// @inheritdoc IReputationSource
    function trustScore(address counterparty) external view returns (uint256) {
        if (!isLinked[counterparty] || _trustedClients.length == 0) return 0;
        (uint64 count, int128 value, uint8 decimals) =
            registry.getSummary(agentIdOf[counterparty], _trustedClients, tag1, tag2);
        if (count < minFeedbackCount || value <= 0 || decimals > 18) return 0;
        uint256 v = uint256(uint128(value)) / (10 ** decimals);
        return v > 100 ? 100 : v;
    }
}
