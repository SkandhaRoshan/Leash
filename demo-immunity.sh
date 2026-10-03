#!/usr/bin/env bash
# Scripted prompt-injection demo; this is not an LLM. Requires a local Anvil fork of Arbitrum One.
# Env: RPC OWNER_KEY LEASH MERCHANT
set -euo pipefail
: "${RPC:?Set RPC to a local Anvil fork}" "${OWNER_KEY:?}" "${LEASH:?}"

CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
NODE_INFO=$(cast rpc anvil_nodeInfo --rpc-url "$RPC" 2>/dev/null) || {
  echo "Refusing to send: RPC does not expose the Anvil nodeInfo method" >&2
  exit 1
}
FORK_URL=$(printf '%s' "$NODE_INFO" | sed -n 's/.*"forkUrl":"\([^"]*\)".*/\1/p')
[ "$CHAIN_ID" = "42161" ] && [ "$FORK_URL" = "https://arb1.arbitrum.io/rpc" ] || {
  echo "Refusing to send: expected a local Anvil fork of Arbitrum One, got chain $CHAIN_ID fork '$FORK_URL'" >&2
  exit 1
}
echo "[guard] Verified local Anvil fork of Arbitrum One at chain $CHAIN_ID"
HERE=$(cd "$(dirname "$0")" && pwd)
REGISTRY=0x8004BAa17C55a88189AE136b182e5fdA19dE9b63
IDENTITY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
MERCHANT=${MERCHANT:-0x000000000000000000000000000000000000dEaD}
EXP=$(($(date +%s) + 86400))

AGENT_ID=
AGENT=
for candidate_id in $(seq 1 10000); do
  candidate_owner=$(cast call "$IDENTITY" "ownerOf(uint256)(address)" "$candidate_id" --rpc-url "$RPC" 2>/dev/null) || continue
  candidate_code=$(cast code "$candidate_owner" --rpc-url "$RPC" 2>/dev/null) || continue
  if [ "$candidate_code" = "0x" ]; then
    AGENT_ID=$candidate_id
    AGENT=$candidate_owner
    break
  fi
done
[ -n "$AGENT_ID" ] || { echo "No EOA-owned ERC-8004 identity found in IDs 1..10000" >&2; exit 1; }
echo "[identity] Discovered agentId $AGENT_ID owned by EOA $AGENT"

own() { cast send "$LEASH" "$@" --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null; }

RESP=$(cat "$HERE/agent/malicious_api_response.txt")
echo "[agent] Scripted weather agent reads API output: $(echo "$RESP" | head -c 90)..."
TARGET=$(echo "$RESP" | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)
AMT=$(echo "$RESP" | grep -o 'for [0-9]* USDG' | grep -o '[0-9]*' | head -1)
echo "[agent] Injected instruction: send $AMT USDG to $TARGET"

echo "[owner] Configure the active agent policy and incident registry"
own "setAllowed(address,bool)" "$MERCHANT" true
own "setPolicy(address,(bool,uint64,uint128,uint128,uint128,uint8))" "$AGENT" "(true,$EXP,50000000,100000000,50000000,0)"
own "setFeedbackRegistry(address)" "$REGISTRY"
own "linkAgentId(address,uint256)" "$AGENT" "$AGENT_ID"
own "setMaxStrikes(uint256)" 3
own "resetStrikes(address)" "$AGENT"

cast rpc anvil_impersonateAccount "$AGENT" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$AGENT" 0x8ac7230489e80000 --rpc-url "$RPC" >/dev/null
trap 'cast rpc anvil_stopImpersonatingAccount "$AGENT" --rpc-url "$RPC" >/dev/null 2>&1 || true' EXIT
echo "[anvil] Impersonating discovered identity owner $AGENT"

FROM_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "[agent] Three injected payment attempts; Leash should block and record each strike"
for strike in 1 2 3; do
  cast send "$LEASH" "tryPay(address,address,uint256)" "$AGENT" "$TARGET" $((AMT*1000000)) --gas-limit 800000 --from "$AGENT" --unlocked --rpc-url "$RPC" >/dev/null
done

PAYMENT_EVENT='PaymentBlocked(address indexed agent,address indexed to,uint256 amount,bytes32 reasonCode)'
BLOCKED=$(cast logs "$PAYMENT_EVENT" "$AGENT" "$TARGET" --from-block "$FROM_BLOCK" --to-block latest --address "$LEASH" --rpc-url "$RPC")
echo "[leash] On-chain blocked attempts:"
echo "$BLOCKED"
for CODE in $(echo "$BLOCKED" | grep -o 'reasonCode: 0x[0-9a-fA-F]\{64\}' | awk '{print $2}'); do
  CODE=$(echo "$CODE" | tr '[:upper:]' '[:lower:]')
  if [ "$CODE" = "$(cast keccak "NotAllowlisted" | tr '[:upper:]' '[:lower:]')" ]; then echo "   reason: NotAllowlisted"
  elif [ "$CODE" = "$(cast keccak "LowTrust" | tr '[:upper:]' '[:lower:]')" ]; then echo "   reason: LowTrust"
  elif [ "$CODE" = "$(cast keccak "ExceedsPerTxCap" | tr '[:upper:]' '[:lower:]')" ]; then echo "   reason: ExceedsPerTxCap"
  else echo "   reason: unknown ($CODE)"; exit 1
  fi
done

echo "[leash] AgentAutoRevoked event:"
cast logs 'AgentAutoRevoked(address indexed agent,uint256 strikes)' "$AGENT" --from-block "$FROM_BLOCK" --to-block latest --address "$LEASH" --rpc-url "$RPC"
echo "[leash] Incident report event:"
cast logs 'IncidentReported(address indexed agent,uint256 indexed agentId,bool success)' "$AGENT" "$AGENT_ID" --from-block "$FROM_BLOCK" --to-block latest --address "$LEASH" --rpc-url "$RPC"
echo "[leash] Recorded strikes: $(cast call "$LEASH" "strikes(address)(uint256)" "$AGENT" --rpc-url "$RPC")"
echo "[registry] getSummary(agentId, [Leash], leash, auto-revoked):"
cast call "$REGISTRY" "getSummary(uint256,address[],string,string)(uint64,int128,uint8)" "$AGENT_ID" "[$LEASH]" "leash" "auto-revoked" --rpc-url "$RPC"
