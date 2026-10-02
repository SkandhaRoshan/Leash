# Leash: on-chain spending policy for AI agents

**Live on Arbitrum Sepolia (testnet, verified). Tested against the live Arbitrum One ERC-8004 registries via fork test.** | 47 unit/fuzz tests, 4 invariant properties, 6 fork tests

> Give your agent a budget, not a private key.

> Give your agent a budget, not a private key.

An AI agent that can spend money is useful. An agent holding a key is a liability.
Leash is a vault where the **contract** enforces what the agent may do, and a compromised
agent key can lose at most one rolling-24h cap, only to counterparties you vetted,
until you revoke it.

## What it enforces (all on-chain, all tested)

| Rule | Behaviour |
|---|---|
| Per-tx cap | Payment above `perTxCap` reverts (`ExceedsPerTxCap`) |
| Rolling 24h cap | Sum over any trailing 24h <= `windowCap` (`WindowCapExceeded`) |
| Session expiry | Agent key dies at `expiry` (`PolicyExpired`) |
| Counterparty rule | Allowlisted address, OR unlisted address whose **ERC-8004 reputation** >= `minTrust`. Default is deny. Fails closed if the reputation source reverts |
| Denylist | Overrides allowlist and reputation |
| Human-in-the-loop | Payments above `approvalThreshold` become pending requests; only the owner can approve (re-validated at approval time; 24h TTL) |
| Kill switch | `revoke(agent)` is instant and also kills that agent's pending requests; `pause()` freezes everything |
## Quick start

Install Foundry and git, then run `./setup.sh` to install dependencies and build. Run `forge test` to execute 39 tests: unit, fuzz, and invariants.

### Local demo

Run anvil, deploy with LocalDev.s.sol, and execute demo.sh. Expected output: one successful payment, then NotAllowlisted, ExceedsPerTxCap, WindowCapExceeded, and NotAgent after revoke, each a real on-chain revert.

### Production deploy

script/Deploy.s.sol refuses to run unless TOKEN is a real contract on the target chain.

ERC-8004 reputation on Arbitrum One: Identity 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432, Reputation 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63, as listed in the official erc-8004/erc-8004-contracts repo. Re-check them yourself.

USDG (per Paxos docs, verify on the explorer): Arbitrum One 0x004B506865409877C9fA29bfb1ebA929984B9bbC; Robinhood Chain (id 4663) 0x5fc5360d0400a0fd4f2af552add042d716f1d168.

After deploying, curate the adapter with setTrustedClient and link using cast send.

## Deployed Addresses

### Arbitrum Sepolia (testnet)
- Leash: `0x15fDBe3F98560297B3001674f81646AcAd3D0683`
- Verified: Sourcify exact match + Blockscout
- Token (test USDC): `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`
- Deployment tx: `0xc362a618e038d62e1c3e3d83711ebe77c8113d51f12b07bb15617491167f19a5`
- Explorer: https://sepolia.arbiscan.io/address/0x15fDBe3F98560297B3001674f81646AcAd3D0683

### Arbitrum One (mainnet)
- Leash: 0x... (paste after deploy)
- ERC8004ReputationAdapter: 0x... (paste after deploy)
- USDG: 0x004B506865409877C9fA29bfb1ebA929984B9bbC

## Tests

**47 unit/fuzz tests, 4 invariant properties, 6 fork tests. 0 failures.**

- 47 unit/fuzz tests: every revert path, approval lifecycle, reputation gating, adapter, circuit breaker (tryPay), time-rolling fuzz
- 4 invariants (256 runs x depth 64, 16,384 calls, 0 reverts): no 24h window exceeds the cap, vault accounting conserves funds, on-chain window view stays within cap, and the circuit breaker cannot bypass the rolling 24h cap
- 6 fork tests against the live Arbitrum One ERC-8004 registry: verifies the adapter reads the real Reputation Registry at 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63, links real agent IDs via the Identity Registry at 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432, and confirms the live registry rejects empty reviewer lists (a bug fixed during the Buildathon)
- Mutation check: weakening the rolling window to 24 buckets makes the fuzz test and the invariant fail

Result on 2026-10-02: 47 unit/fuzz tests passed, 4 invariants passed, 6 fork tests passed, 0 failed.

## Static Analysis

Slither 0.11.6 analyzed 16 contracts with 102 detectors. **0 High, 0 Critical findings.**

Findings in Leash code:
- weak-prng in Leash._spend: false positive. id % BUCKETS is a bucket index for the rolling window, not a random number.
- unused-return in ERC8004ReputationAdapter.link: accepted. ownerOf reverts if the token does not exist.
- costly-loop in ERC8004ReputationAdapter.setTrustedClient: accepted. Admin-only function, called rarely.
- timestamp in multiple functions: accepted. Rolling windows and expiry require block.timestamp. Intentional design.

9 findings in OpenZeppelin Contracts 5.x library code, not in Leash code.

**No external audit. Slither static analysis only.**

## Threat model

Agent key stolen or prompt-injected: caps, allowlist, reputation gate, expiry, approval threshold, revoke. Residual risk: loses up to windowCap per 24h to vetted counterparties before you notice.

Malicious allowlisted merchant: per-tx and window caps bound the loss.

USDG issuer controls: Leash moves funds via safeTransfer only. Paxos can pause or freeze USDG. Leash cannot override.

Reputation gaming: only feedback from admin-curated reviewers counts (max 20). ERC-8004 reputation is gameable and score scales are not standardized. Treat as a risk signal.

Owner key compromise: Ownable2Step, pause. Owner is fully trusted. Use a multisig.

Reentrancy: nonReentrant, SafeERC20, checks-effects ordering.

Rolling window: 25 hourly buckets, conservative. Effective window 24-25 hours and can never exceed the cap over any real 24h interval.

## What is NOT done

No external audit. Slither static analysis is included above.
x402 / EIP-3009: payments are plain ERC-20 transfers. Facilitator-signed flows are future work.
ERC-8004 adapter: verified against live Arbitrum One registries via fork test (6/6 passed 2026-10-02). Real bug found and fixed: live Reputation Registry rejects empty reviewer lists. Feedback value scale assumed 0..100.
Stylus: policy evaluator is Solidity. Porting window math to Stylus is a possible extension.
Dashboard: checked against a live local contract but not clicked through in a real browser wallet.
Injection demo agent is scripted, not a real LLM.

## License

MIT
