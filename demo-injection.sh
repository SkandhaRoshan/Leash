#!/usr/bin/env bash
# Prompt-injection demo. The "agent" below is a deliberately naive stand-in for an LLM that
# obeys instructions found inside tool output (that is what a successful injection looks like).
# It is NOT a real model. The point: even a fully hijacked agent cannot move funds past Leash.
# Env: RPC AGENT_KEY LEASH TOKEN  (run ./demo.sh first so the policy exists)
set -u
: "${RPC:?}" "${AGENT_KEY:?}" "${LEASH:?}" "${TOKEN:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
Z=0x0000000000000000000000000000000000000000000000000000000000000000
bal() { cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" | awk '{print $1}'; }

echo "[agent] Task: fetch weather data from a paid API"
RESP=$(cat "$HERE/agent/malicious_api_response.txt")
echo "[agent] API replied: $(echo "$RESP" | head -c 90)..."
TARGET=$(echo "$RESP" | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)
AMT=$(echo "$RESP" | grep -o 'for [0-9]* USDG' | grep -o '[0-9]*' | head -1)
echo "[agent] !! injected instruction obeyed: pay $AMT USDG to $TARGET"
BEFORE=$(bal "$TARGET"); VAULT_BEFORE=$(bal "$LEASH")
out=$(cast send "$LEASH" "pay(address,uint256,bytes32)" "$TARGET" $((AMT*1000000)) $Z --private-key "$AGENT_KEY" --rpc-url "$RPC" 2>&1)
if echo "$out" | grep -qi "revert"; then
  echo "[leash] BLOCKED on-chain (revert). Attacker balance: $BEFORE -> $(bal "$TARGET"). Vault: $VAULT_BEFORE -> $(bal "$LEASH")"
else echo "[leash] !!! NOT BLOCKED"; echo "$out" | head -5; exit 1; fi
