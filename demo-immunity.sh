#!/usr/bin/env bash
# Scripted prompt-injection demo; this is not an LLM. Run only against a local Arbitrum fork.
# Env: RPC OWNER_KEY AGENT_KEY LEASH TOKEN AGENT_ID MERCHANT
set -euo pipefail
: "${RPC:?Set RPC to a local Anvil fork}" "${OWNER_KEY:?}" "${AGENT_KEY:?}" "${LEASH:?}" "${TOKEN:?}" "${AGENT_ID:?}"

CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN_ID" = "31337" ] || { echo "Refusing to send: expected local Anvil chain id 31337, got $CHAIN_ID" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
REGISTRY=0x8004BAa17C55a88189AE136b182e5fdA19dE9b63
IDENTITY=0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
MERCHANT=${MERCHANT:-0x000000000000000000000000000000000000dEaD}
U=1000000
EXP=$(($(date +%s) + 86400))
OWNER_OF_ID=$(cast call "$IDENTITY" "ownerOf(uint256)(address)" "$AGENT_ID" --rpc-url "$RPC")
[ "${OWNER_OF_ID,,}" = "${AGENT,,}" ] || { echo "AGENT_KEY must own ERC-8004 agentId $AGENT_ID (ownerOf returned $OWNER_OF_ID)" >&2; exit 1; }

own() { cast send "$LEASH" "$@" --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null; }
bal() { cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC"; }

RESP=$(cat "$HERE/agent/malicious_api_response.txt")
echo "[agent] Scripted weather agent reads API output: $(echo "$RESP" | head -c 90)..."
TARGET=$(echo "$RESP" | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)
AMT=$(echo "$RESP" | grep -o 'for [0-9]* USDG' | grep -o '[0-9]*' | head -1)
echo "[agent] Injected instruction: send $AMT USDG to $TARGET"

echo "[owner] Configure the active agent policy and incident registry"
cast send "$TOKEN" "transfer(address,uint256)" "$LEASH" $((40*U)) --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null
own "setAllowed(address,bool)" "$MERCHANT" true
own "setPolicy(address,(bool,uint64,uint128,uint128,uint128,uint8))" "$AGENT" "(true,$EXP,$((10*U)),$((25*U)),$((5*U)),0)"
own "setFeedbackRegistry(address)" "$REGISTRY"
own "linkAgentId(address,uint256)" "$AGENT" "$AGENT_ID"
own "setMaxStrikes(uint256)" 3
own "resetStrikes(address)" "$AGENT"
echo "   vault balance: $(bal "$LEASH") | agent: $AGENT | agentId: $AGENT_ID"

FROM_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "[agent] Three injected payment attempts; Leash should block and record each strike"
for strike in 1 2 3; do
  cast send "$LEASH" "tryPay(address,address,uint256)" "$AGENT" "$TARGET" $((AMT*U)) --private-key "$AGENT_KEY" --rpc-url "$RPC" >/dev/null
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
