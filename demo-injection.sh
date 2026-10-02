#!/usr/bin/env bash
# Prompt-injection demo. The "agent" is a scripted stand-in for an LLM obeying tool output.
# Env: RPC OWNER_KEY AGENT_KEY LEASH TOKEN
set -u
: "${RPC:?}" "${OWNER_KEY:?}" "${AGENT_KEY:?}" "${LEASH:?}" "${TOKEN:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
OWNER=$(cast wallet address --private-key "$OWNER_KEY")
MERCHANT=${MERCHANT:-0x000000000000000000000000000000000000dEaD}
U=1000000
EXP=$(($(date +%s) + 86400))
bal() { cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | awk '{print $1}'; }

echo "[agent] Task: fetch weather data from a paid API"
RESP=$(cat "$HERE/agent/malicious_api_response.txt")
echo "[agent] API replied: $(echo "$RESP" | head -c 90)..."
TARGET=$(echo "$RESP" | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)
AMT=$(echo "$RESP" | grep -o 'for [0-9]* USDG' | grep -o '[0-9]*' | head -1)
echo "[agent] !! injected instruction obeyed: pay $AMT USDG to $TARGET"

echo "[owner] Fund vault and configure active policy (merchant allowlisted, minTrust 80)"
cast send "$TOKEN" "transfer(address,uint256)" "$LEASH" $((40*U)) --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null
cast send "$LEASH" "setAllowed(address,bool)" "$MERCHANT" true --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null
cast send "$LEASH" "setPolicy(address,(bool,uint64,uint128,uint128,uint128,uint8))" "$AGENT" "(true,$EXP,$((10*U)),$((25*U)),$((5*U)),80)" --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null
echo "   merchant: $MERCHANT | vault balance: $(bal "$LEASH")"
echo "[owner] Agent key ready: $AGENT"

echo "[agent] Attempt transfer to unlisted attacker: $TARGET"
FROM_BLOCK=$(cast block-number --rpc-url "$RPC")
cast send "$LEASH" "tryPay(address,address,uint256)" "$AGENT" "$TARGET" $((AMT*U)) --private-key "$AGENT_KEY" --rpc-url "$RPC" >/dev/null

# Event declaration is taken from out/Leash.sol/Leash.json: both addresses are indexed.
EVENT='PaymentBlocked(address indexed agent,address indexed to,uint256 amount,bytes32 reasonCode)'
logs=$(cast logs "$EVENT" "$AGENT" "$TARGET" --from-block "$FROM_BLOCK" --to-block latest --address "$LEASH" --rpc-url "$RPC")
echo "[leash] Decoded on-chain event:"
echo "$logs"
REASON_CODE=$(echo "$logs" | grep -o 'reasonCode: 0x[0-9a-fA-F]\{64\}' | awk '{print $2}' | tail -1)
[ -n "$REASON_CODE" ] || { echo "[leash] No PaymentBlocked reason found"; exit 1; }
REASON_CODE=$(echo "$REASON_CODE" | tr '[:upper:]' '[:lower:]')
if [ "$REASON_CODE" = "$(cast keccak "NotAllowlisted" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "[leash] BLOCKED: NotAllowlisted"
elif [ "$REASON_CODE" = "$(cast keccak "LowTrust" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "[leash] BLOCKED: LowTrust"
else
  echo "[leash] Unexpected reason code: $REASON_CODE"
  exit 1
fi
echo "[leash] Strike count: $(cast call "$LEASH" "getStrikes(address)(uint256)" "$AGENT" --rpc-url "$RPC")"
