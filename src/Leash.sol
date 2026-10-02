// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IReputationSource} from "./interfaces/IReputationSource.sol";

/// @title Leash
/// @notice A spending vault for AI agents. The owner funds it with a stablecoin (e.g. USDG)
///         and grants each agent session key a Policy. The CONTRACT enforces the policy:
///         per-tx cap, rolling 24h cap, expiry, counterparty rules (allowlist OR minimum
///         on-chain reputation), and owner approval for large payments.
///         The agent key never holds funds; a compromised key can lose at most `windowCap`
///         per rolling 24h, only to vetted counterparties, until the owner revokes it.
contract Leash is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types
    struct Policy {
        bool active;
        uint64 expiry; // session key stops working at this timestamp
        uint128 perTxCap; // max amount per payment
        uint128 windowCap; // max total over any rolling 24h
        uint128 approvalThreshold; // payments ABOVE this need owner approval
        uint8 minTrust; // 0 = allowlist only; else accept unlisted counterparties with trustScore >= this
    }

    struct Bucket {
        uint64 id;
        uint192 amount;
    }

    enum Status {
        None,
        Pending,
        Executed,
        Rejected
    }

    struct Request {
        address agent;
        address to;
        uint128 amount;
        uint64 createdAt;
        bytes32 ref;
        Status status;
    }

    // -------------------------------------------------------------- constants
    uint256 public constant BUCKET_SIZE = 1 hours;
    /// @dev A real 24h interval can touch 25 hourly buckets, so summing the last 25
    ///      is a conservative (never-exceeds-cap) rolling window.
    uint256 public constant BUCKETS = 25;
    uint256 public constant REQUEST_TTL = 1 days;

    bytes32 public constant REASON_EXCEEDS_PER_TX_CAP = keccak256("ExceedsPerTxCap");
    bytes32 public constant REASON_WINDOW_CAP_EXCEEDED = keccak256("WindowCapExceeded");
    bytes32 public constant REASON_NOT_ALLOWLISTED = keccak256("NotAllowlisted");
    bytes32 public constant REASON_LOW_TRUST = keccak256("LowTrust");
    bytes32 public constant REASON_POLICY_EXPIRED = keccak256("PolicyExpired");
    bytes32 public constant REASON_NOT_AGENT = keccak256("NotAgent");
    bytes32 public constant REASON_PAUSED = keccak256("Paused");
    bytes32 public constant REASON_ZERO_AMOUNT = keccak256("ZeroAmount");
    bytes32 public constant REASON_DENYLISTED = keccak256("Denylisted");
    bytes32 public constant REASON_APPROVAL_REQUIRED = keccak256("ApprovalRequired");

    // ---------------------------------------------------------------- storage
    IERC20 public immutable token;
    IReputationSource public reputation;

    mapping(address => Policy) public policies;
    mapping(address => bool) public allowlist;
    mapping(address => bool) public denylist;
    mapping(address => Bucket[25]) private _buckets;
    mapping(address => uint256) public strikes;
    uint256 public maxStrikes = 3;

    uint256 public nextRequestId = 1;
    mapping(uint256 => Request) public requests;

    // ----------------------------------------------------------------- events
    event PolicySet(address indexed agent, Policy policy);
    event AgentRevoked(address indexed agent);
    event Paid(address indexed agent, address indexed to, uint256 amount, bytes32 ref);
    event ApprovalRequested(uint256 indexed id, address indexed agent, address indexed to, uint256 amount, bytes32 ref);
    event RequestApproved(uint256 indexed id);
    event RequestRejected(uint256 indexed id);
    event AllowlistSet(address indexed account, bool allowed);
    event DenylistSet(address indexed account, bool denied);
    event ReputationSourceSet(address indexed source);
    event Withdrawn(address indexed to, uint256 amount);
    /// @notice Emitted when a payment attempt is blocked by a policy check.
    event PaymentBlocked(address indexed agent, address indexed to, uint256 amount, bytes32 reasonCode);
    /// @notice Emitted when an agent is automatically revoked after reaching the strike limit.
    event AgentAutoRevoked(address indexed agent, uint256 strikes);

    // ----------------------------------------------------------------- errors
    error NotAgent();
    error PolicyExpired();
    error InvalidPolicy();
    error ZeroAmount();
    error ExceedsPerTxCap(uint256 amount, uint256 cap);
    error WindowCapExceeded(uint256 spent, uint256 amount, uint256 cap);
    error CounterpartyDenied(address to);
    error NotAllowlisted(address to);
    error TrustTooLow(uint256 score, uint256 required);
    error TrustUnavailable(address to);
    error BadRequest();
    error RequestExpired();
    error ZeroAddress();

    constructor(address token_, address owner_) Ownable(owner_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
    }

    // ============================================================ agent actions

    /// @notice Pay `to` from the vault. Reverts if any policy rule is violated.
    ///         If `amount` exceeds the policy's approvalThreshold, a pending request is
    ///         created instead and the owner must approve it.
    /// @return requestId 0 if paid immediately, else the pending request id.
    function pay(address to, uint256 amount, bytes32 ref) external whenNotPaused nonReentrant returns (uint256 requestId) {
        Policy memory p = _activePolicy(msg.sender);
        _checkPayment(p, to, amount);

        if (amount > p.approvalThreshold) {
            requestId = nextRequestId++;
            requests[requestId] = Request(msg.sender, to, uint128(amount), uint64(block.timestamp), ref, Status.Pending);
            emit ApprovalRequested(requestId, msg.sender, to, amount, ref);
            return requestId;
        }
        _spend(msg.sender, p, to, amount, ref);
    }

    /// @notice Attempts a direct payment without reverting on policy violations.
    /// @dev The caller must be the supplied agent; runtime failures such as token transfer errors still revert.
    function tryPay(address agent, address to, uint256 amount) external nonReentrant returns (bool success) {
        address strikeAgent = agent == msg.sender ? agent : msg.sender;
        bytes32 reasonCode;
        Policy memory p = policies[agent];

        if (paused()) reasonCode = REASON_PAUSED;
        else if (agent != msg.sender || !p.active) reasonCode = REASON_NOT_AGENT;
        else if (block.timestamp >= p.expiry) reasonCode = REASON_POLICY_EXPIRED;
        else if (amount == 0) reasonCode = REASON_ZERO_AMOUNT;
        else if (amount > p.perTxCap) reasonCode = REASON_EXCEEDS_PER_TX_CAP;
        else if (denylist[to]) reasonCode = REASON_DENYLISTED;
        else if (!allowlist[to]) {
            if (p.minTrust == 0 || address(reputation) == address(0)) {
                reasonCode = REASON_NOT_ALLOWLISTED;
            } else {
                try reputation.trustScore(to) returns (uint256 score) {
                    if (score < p.minTrust) reasonCode = REASON_LOW_TRUST;
                } catch {
                    reasonCode = REASON_LOW_TRUST;
                }
            }
        }

        if (reasonCode == bytes32(0) && amount > p.approvalThreshold) {
            reasonCode = REASON_APPROVAL_REQUIRED;
        }
        if (reasonCode == bytes32(0) && windowSpent(agent) + amount > p.windowCap) {
            reasonCode = REASON_WINDOW_CAP_EXCEEDED;
        }

        if (reasonCode != bytes32(0)) {
            _recordBlockedPayment(strikeAgent, to, amount, reasonCode);
            return false;
        }

        _spend(agent, p, to, amount, bytes32(0));
        return true;
    }

    // ============================================================ owner actions

    function approve(uint256 id) external onlyOwner whenNotPaused nonReentrant {
        Request storage r = requests[id];
        if (r.status != Status.Pending) revert BadRequest();
        if (block.timestamp > r.createdAt + REQUEST_TTL) revert RequestExpired();
        r.status = Status.Executed;

        // Re-validate against CURRENT policy/lists: a revoked agent's request must not execute.
        Policy memory p = _activePolicy(r.agent);
        _checkPayment(p, r.to, r.amount);
        _spend(r.agent, p, r.to, r.amount, r.ref);
        emit RequestApproved(id);
    }

    function reject(uint256 id) external {
        Request storage r = requests[id];
        if (r.status != Status.Pending) revert BadRequest();
        if (msg.sender != owner() && msg.sender != r.agent) revert BadRequest();
        r.status = Status.Rejected;
        emit RequestRejected(id);
    }

    function setPolicy(address agent, Policy calldata p) external onlyOwner {
        if (agent == address(0) || agent == owner()) revert InvalidPolicy();
        if (p.expiry <= block.timestamp || p.perTxCap == 0 || p.windowCap < p.perTxCap || p.minTrust > 100) {
            revert InvalidPolicy();
        }
        Policy memory stored = p;
        stored.active = true;
        policies[agent] = stored;
        emit PolicySet(agent, stored);
    }

    /// @notice Instantly disable an agent. Pending requests from it become unexecutable.
    function revoke(address agent) external onlyOwner {
        _revokeAgent(agent);
    }

    function _revokeAgent(address agent) internal {
        policies[agent].active = false;
        emit AgentRevoked(agent);
    }

    /// @notice Clears the recorded policy-violation strikes for an agent.
    function resetStrikes(address agent) external onlyOwner {
        strikes[agent] = 0;
    }

    /// @notice Sets the strike threshold for automatic agent revocation.
    function setMaxStrikes(uint256 n) external onlyOwner {
        require(n >= 1 && n <= 10, "MaxStrikes out of bounds");
        maxStrikes = n;
    }

    function setAllowed(address account, bool allowed) external onlyOwner {
        allowlist[account] = allowed;
        emit AllowlistSet(account, allowed);
    }

    function setDenied(address account, bool denied) external onlyOwner {
        denylist[account] = denied;
        emit DenylistSet(account, denied);
    }

    function setReputationSource(address source) external onlyOwner {
        reputation = IReputationSource(source);
        emit ReputationSourceSet(source);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    // ================================================================== views

    /// @notice Total spent by `agent` over the conservative rolling 24h window.
    function windowSpent(address agent) public view returns (uint256 total) {
        uint256 nowId = block.timestamp / BUCKET_SIZE;
        for (uint256 i = 0; i < BUCKETS; i++) {
            Bucket memory b = _buckets[agent][i];
            if (b.amount != 0 && b.id + BUCKETS > nowId && b.id <= nowId) total += b.amount;
        }
    }

    function remainingAllowance(address agent) external view returns (uint256) {
        Policy memory p = policies[agent];
        if (!p.active || block.timestamp >= p.expiry) return 0;
        uint256 spent = windowSpent(agent);
        return spent >= p.windowCap ? 0 : p.windowCap - spent;
    }

    function getStrikes(address agent) external view returns (uint256) {
        return strikes[agent];
    }

    /// @notice Dry-run: returns "" if `agent` could pay now, else a short reason.
    ///         Does not check the approval threshold or pause state of the token balance.
    function checkPayment(address agent, address to, uint256 amount) external view returns (string memory) {
        if (paused()) return "PAUSED";
        Policy memory p = policies[agent];
        if (!p.active) return "NOT_AGENT";
        if (block.timestamp >= p.expiry) return "EXPIRED";
        if (amount == 0) return "ZERO_AMOUNT";
        if (amount > p.perTxCap) return "PER_TX_CAP";
        if (denylist[to]) return "DENYLISTED";
        if (!allowlist[to]) {
            if (p.minTrust == 0 || address(reputation) == address(0)) return "NOT_ALLOWLISTED";
            try reputation.trustScore(to) returns (uint256 s) {
                if (s < p.minTrust) return "TRUST_TOO_LOW";
            } catch {
                return "TRUST_UNAVAILABLE";
            }
        }
        if (windowSpent(agent) + amount > p.windowCap) return "WINDOW_CAP";
        return "";
    }

    // ============================================================== internals

    function _activePolicy(address agent) internal view returns (Policy memory p) {
        p = policies[agent];
        if (!p.active) revert NotAgent();
        if (block.timestamp >= p.expiry) revert PolicyExpired();
    }

    function _checkPayment(Policy memory p, address to, uint256 amount) internal view {
        if (amount == 0) revert ZeroAmount();
        if (amount > p.perTxCap) revert ExceedsPerTxCap(amount, p.perTxCap);
        if (denylist[to]) revert CounterpartyDenied(to);
        if (allowlist[to]) return;
        if (p.minTrust == 0 || address(reputation) == address(0)) revert NotAllowlisted(to);
        try reputation.trustScore(to) returns (uint256 score) {
            if (score < p.minTrust) revert TrustTooLow(score, p.minTrust);
        } catch {
            revert TrustUnavailable(to);
        }
    }

    function _spend(address agent, Policy memory p, address to, uint256 amount, bytes32 ref) internal {
        uint256 spent = windowSpent(agent);
        if (spent + amount > p.windowCap) revert WindowCapExceeded(spent, amount, p.windowCap);

        uint64 id = uint64(block.timestamp / BUCKET_SIZE);
        Bucket storage b = _buckets[agent][id % BUCKETS];
        if (b.id != id) {
            b.id = id;
            b.amount = 0;
        }
        b.amount += uint192(amount);

        token.safeTransfer(to, amount);
        emit Paid(agent, to, amount, ref);
    }

    function _recordBlockedPayment(address agent, address to, uint256 amount, bytes32 reasonCode) internal {
        emit PaymentBlocked(agent, to, amount, reasonCode);
        strikes[agent]++;
        if (strikes[agent] >= maxStrikes && policies[agent].active) {
            _revokeAgent(agent);
            emit AgentAutoRevoked(agent, strikes[agent]);
        }
    }
}
