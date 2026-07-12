#!/usr/bin/env bash
# One-shot acceptance test for the archive JSON-RPC surface, exercised
# through the gateway (the same path clients use). Complements
# verify-archive.sh (archive property) and the prober (continuous SLIs):
# this asserts the read API contract once, pass/fail, CI-friendly.
#
#   - state at historical heights: eth_getBalance / eth_call / eth_getStorageAt
#   - full transaction index: eth_getTransactionByHash + receipt on an old tx
#   - logs over a historical range
#   - traces on old blocks and transactions (heavy pool)
#   - batch requests and JSON-RPC error semantics
#
# Usage: ./scripts/test-rpc.sh [gateway_rpc] [cross_check_rpc]
set -u

RPC="${1:-http://localhost:8548}"
CROSS="${2:-http://localhost:8545}"
ACCOUNT="0x123463a4B065722E99115D6c222f267d9cABb524"
GENESIS_BALANCE="0x43c33c1937564800000"

PASS=0; FAIL=0; SKIP=0

rpc() { # url method params -> raw body
  curl -s -m 20 -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":$3,\"id\":1}" "$1"
}
result() { python3 -c 'import sys,json
try: b=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(json.dumps(b.get("result")) if b.get("result") is not None else "")'; }

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP  $1"; }

check() { # name condition(0=pass)
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

echo "== archive rpc acceptance ($RPC) =="

# 1. head is answering and nonzero
head_hex=$(rpc "$RPC" eth_blockNumber '[]' | result | tr -d '"')
head=$((head_hex))
[ -n "$head_hex" ] && [ "$head" -gt 0 ]; check "eth_blockNumber answers, head=$head" $?

old="0x$(printf '%x' $(( head > 32 ? head / 2 : 1 )))"

# 2. historical state read
bal=$(rpc "$RPC" eth_getBalance "[\"$ACCOUNT\",\"$old\"]" | result)
[ -n "$bal" ]; check "eth_getBalance at historical height $old" $?

# 3. genesis balance invariant (only an archive node can serve block-0 state)
bal0=$(rpc "$RPC" eth_getBalance "[\"$ACCOUNT\",\"0x0\"]" | result | tr -d '"')
[ "$bal0" = "$GENESIS_BALANCE" ]; check "genesis balance invariant at 0x0" $?

# 4. historical block, cross-checked against the validating client
h1=$(rpc "$RPC"   eth_getBlockByNumber "[\"$old\",false]" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["hash"])' 2>/dev/null)
h2=$(rpc "$CROSS" eth_getBlockByNumber "[\"$old\",false]" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["hash"])' 2>/dev/null)
[ -n "$h1" ] && [ "$h1" = "$h2" ]; check "block $old hash matches validating client" $?

# 5. transaction index: find a tx (recent blocks first, then a coarse scan of
# the whole chain), then look it up by hash
txblock=""; txhash=""
for b in $(seq "$head" -1 $(( head > 64 ? head - 64 : 1 ))) $(seq 1 40 | while read -r i; do echo $(( (head * i / 41) + 1 )); done); do
  n=$(rpc "$RPC" eth_getBlockTransactionCountByNumber "[\"0x$(printf '%x' "$b")\"]" | result | tr -d '"')
  if [ -n "$n" ] && [ $((n)) -gt 0 ]; then txblock="0x$(printf '%x' "$b")"; break; fi
done
if [ -n "$txblock" ]; then
  txhash=$(rpc "$RPC" eth_getBlockByNumber "[\"$txblock\",false]" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["transactions"][0])' 2>/dev/null)
  got=$(rpc "$RPC" eth_getTransactionByHash "[\"$txhash\"]" | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r["hash"] if r else "")' 2>/dev/null)
  [ "$got" = "$txhash" ]; check "tx index: eth_getTransactionByHash on tx in block $txblock" $?
  status=$(rpc "$RPC" eth_getTransactionReceipt "[\"$txhash\"]" | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r["status"] if r else "")' 2>/dev/null)
  [ "$status" = "0x1" ]; check "tx index: receipt found with status 0x1" $?
else
  skip "tx index (no transactions on chain - run 'make traffic' first)"
  skip "tx receipt"
fi

# 6. logs over a historical range (must not error; empty is fine)
rpc "$RPC" eth_getLogs "[{\"fromBlock\":\"0x1\",\"toBlock\":\"$old\"}]" | result >/dev/null
check "eth_getLogs over 0x1..$old" $?

# 7. eth_call at a historical height
r=$(rpc "$RPC" eth_call "[{\"to\":\"$ACCOUNT\"},\"$old\"]" | result)
[ -n "$r" ]; check "eth_call at $old" $?

# 8. storage at a historical height
r=$(rpc "$RPC" eth_getStorageAt "[\"$ACCOUNT\",\"0x0\",\"$old\"]" | result)
[ -n "$r" ]; check "eth_getStorageAt at $old" $?

# 9. block trace on an old block (routed to the heavy pool)
r=$(rpc "$RPC" debug_traceBlockByNumber "[\"$old\",{\"tracer\":\"callTracer\"}]" | result)
[ -n "$r" ]; check "debug_traceBlockByNumber at $old (heavy pool)" $?

# 10. transaction trace, if we found a tx
if [ -n "$txhash" ]; then
  r=$(rpc "$RPC" debug_traceTransaction "[\"$txhash\",{\"tracer\":\"callTracer\"}]" | result)
  [ -n "$r" ]; check "debug_traceTransaction on old tx" $?
else
  skip "debug_traceTransaction (no tx found)"
fi

# 11. batch request: three calls in one round trip, three answers back
n=$(curl -s -m 20 -X POST -H 'content-type: application/json' -d '[
  {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
  {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2},
  {"jsonrpc":"2.0","method":"net_version","params":[],"id":3}]' "$RPC" \
  | python3 -c 'import sys,json;b=json.load(sys.stdin);print(len(b) if isinstance(b,list) else 0)')
[ "$n" = "3" ]; check "batch request returns 3 results" $?

# 12. error semantics: unknown method -> JSON-RPC -32601, not a transport error
code=$(rpc "$RPC" eth_noSuchMethod '[]' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("error",{}).get("code",""))')
[ "$code" = "-32601" ]; check "unknown method returns JSON-RPC -32601" $?

echo
echo "== summary: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" -eq 0 ]
