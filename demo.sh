#!/usr/bin/env bash
# 90-second demo: fund -> agent pays -> every attack reverts on-chain -> revoke mid-task.
# Env: RPC, OWNER_KEY, AGENT_KEY, LEASH, TOKEN   (see README)
set -u
: "${RPC:?}" "${OWNER_KEY:?}" "${AGENT_KEY:?}" "${LEASH:?}" "${TOKEN:?}"
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
MERCHANT=${MERCHANT:-0x000000000000000000000000000000000000dEaD}
ATTACKER=${ATTACKER:-0x000000000000000000000000000000000000bEEF}
U=1000000
Z=0x0000000000000000000000000000000000000000000000000000000000000000
[ "$(cast balance "$AGENT" --rpc-url "$RPC")" != "0" ] || { echo "Agent $AGENT has no gas ETH - fund it first"; exit 1; }
EXP=$(( $(date +%s) + 86400 ))
own() { cast send "$LEASH" "$@" --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null; }
agt() { cast send "$LEASH" "$@" --private-key "$AGENT_KEY" --rpc-url "$RPC" 2>&1; }
bal() { cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC"; }
decode() { # map a custom-error selector to its Leash error name
  local sel; sel=$(echo "$1" | grep -io 'custom error 0x[0-9a-f]*' | head -1 | awk '{print $3}')
  [ -z "$sel" ] && { echo "$1" | head -c 80; return; }
  for e in "ExceedsPerTxCap(uint256,uint256)" "WindowCapExceeded(uint256,uint256,uint256)" "NotAllowlisted(address)" "CounterpartyDenied(address)" "TrustTooLow(uint256,uint256)" "TrustUnavailable(address)" "NotAgent()" "PolicyExpired()" "ZeroAmount()" "ERC20InsufficientBalance(address,uint256,uint256)"; do
    [ "$(cast sig "$e")" = "$sel" ] && { echo "${e%%(*}"; return; }
  done; echo "$sel"
}
attack() { # label, args...  (counts ONLY a genuine on-chain revert as BLOCKED)
  local label=$1; shift
  out=$(agt "$@")
  if echo "$out" | grep -qi "connect\|error sending request"; then echo "  ?? RPC ERROR (not a valid test): $label"; exit 1
  elif echo "$out" | grep -qi "revert"; then echo "  BLOCKED  $label  -> $(decode "$out")"
  else echo "  !!! NOT BLOCKED: $label"; exit 1; fi
}

echo "== 1. Owner funds vault with 40 USDG and sets policy (10/tx, 25/day, approve >5, allowlist merchant)"
cast send "$TOKEN" "transfer(address,uint256)" "$LEASH" $((40*U)) --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null
own "setAllowed(address,bool)" "$MERCHANT" true
own "setPolicy(address,(bool,uint64,uint128,uint128,uint128,uint8))" "$AGENT" "(true,$EXP,$((10*U)),$((25*U)),$((5*U)),0)"
echo "   vault balance: $(bal "$LEASH")"

echo "== 2. Agent pays approved merchant 3 USDG (x402-style API call)"
agt "pay(address,uint256,bytes32)" "$MERCHANT" $((3*U)) 0x6170692d63616c6c000000000000000000000000000000000000000000000000 >/dev/null
echo "   merchant balance: $(bal "$MERCHANT")"

echo "== 3. Attacks (each must revert on-chain)"
attack "pay unlisted attacker address"      "pay(address,uint256,bytes32)" "$ATTACKER" $((1*U)) $Z
attack "pay 11 USDG (over 10 per-tx cap)"   "pay(address,uint256,bytes32)" "$MERCHANT" $((11*U)) $Z
echo "   agent hits daily cap with approved merchant:"
agt "pay(address,uint256,bytes32)" "$MERCHANT" $((5*U)) $Z >/dev/null
agt "pay(address,uint256,bytes32)" "$MERCHANT" $((5*U)) $Z >/dev/null
agt "pay(address,uint256,bytes32)" "$MERCHANT" $((5*U)) $Z >/dev/null
agt "pay(address,uint256,bytes32)" "$MERCHANT" $((5*U)) $Z >/dev/null
attack "pay beyond 25 USDG rolling daily cap" "pay(address,uint256,bytes32)" "$MERCHANT" $((5*U)) $Z
echo "   remaining allowance: $(cast call "$LEASH" "remainingAllowance(address)(uint256)" "$AGENT" --rpc-url "$RPC")"

echo "== 4. Owner revokes agent mid-task"
own "revoke(address)" "$AGENT"
attack "pay after revoke" "pay(address,uint256,bytes32)" "$MERCHANT" $((1*U)) $Z
echo "== done. Merchant total: $(bal "$MERCHANT")  |  vault left: $(bal "$LEASH")"
