# Leash Design Notes

## Spending window: 25 hourly buckets

Leash indexes spend into one-hour buckets and sums the most recent 25 buckets. A real trailing 24-hour interval can overlap 25 buckets when it starts and ends partway through hours. Summing all 25 is conservative: it may temporarily count spend older than 24 hours, but it prevents a rolling-window cap bypass. The tradeoff is that usable allowance can recover as late as roughly 25 hours after an earlier payment.

## Strikes and automatic revocation

`tryPay` is the non-reverting policy path. A blocked call emits a reason code and increments only the caller's strike counter; supplying another agent address does not write strikes against that target. Strike increments saturate at `uint256.max` to keep the blocked path from overflowing. At `maxStrikes`, Leash deactivates the policy and emits revocation events. Existing pending approvals remain recorded, but approval revalidates the now-inactive policy and reverts; the owner or agent can still reject a pending request.

## Incident report isolation

After deactivation, Leash revalidates that the linked ERC-8004 identity is still owned by that exact agent key. This prevents a previously linked key from reporting against an identity after its NFT has moved to a successor. It also checks that the configured feedback registry is the same registry used at link time.

The Identity Registry owner check and Reputation Registry `giveFeedback` call are separately gas-capped. The report itself receives at most 300,000 gas, while a reserve is kept for Leash to emit `IncidentReportFailed` if the call cannot be attempted. Both external calls are caught; either may fail without rolling back revocation. `tryPay` and `setPolicy` share the `nonReentrant` guard. This matters if a registry is also Leash's owner: its callback cannot reenter `setPolicy` and reactivate the agent. Policy state is inactive before the registry callback, so a malicious registry cannot reenter a payment path or reverse revocation. The tradeoff is that callers must supply enough outer transaction gas for the guard and capped call; otherwise revocation still completes but the report is skipped and failure is emitted.

## Trusted reviewers

ERC-8004 stores public feedback, but a score is meaningful only under the consumer's chosen reviewer policy. Leash's reputation adapter uses an owner-curated reviewer list and a minimum feedback count. Other protocols must independently decide whether to trust Leash as a client. An incident event or report does not automatically propagate consequences across protocols; herd immunity depends on adoption.

## Identity ownership and session keys

`linkAgentId` requires the current Identity Registry `ownerOf(agentId)` to equal the Leash agent key. This prevents an unrelated key from linking another identity and aligns the feedback author with the attributed agent. It also couples a sensitive ERC-721 identity to the session key. If that key is hot or compromised, the identity token and its agent actions share a control boundary. Teams should weigh whether that is acceptable before linking a production identity; Leash deliberately fails closed if ownership changes later.

## Feedback semantics

On automatic revocation, Leash submits value `-100`, zero decimals, and tags `leash` / `auto-revoked`. ERC-8004 defines the storage and aggregation interface, not a universal interpretation of this scale or those tags. Consumers must not treat the report as adjudicated evidence.

## Operational status

The demos use scripted agents, not an LLM. The dashboard was checked against a local Anvil deployment using a stubbed browser provider; it has not been verified with MetaMask. There has been no external audit.
