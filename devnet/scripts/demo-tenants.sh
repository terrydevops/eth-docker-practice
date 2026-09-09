#!/usr/bin/env bash
# Plays the three gateway tenants for DURATION seconds so the Serving Layer
# dashboard shows each of them: compliance reads and now and then tries a
# trace (403), forensics traces and bursts past its limit (429), and a
# client without a key keeps knocking (401). Prints the status counts.
#
# Usage: ./scripts/demo-tenants.sh [seconds]   (keys from ../.env)
set -u
RPC="${RPC:-http://localhost:8548}"
DURATION="${1:-60}"
ENVFILE="$(dirname "$0")/../.env"
C=$(grep '^GATEWAY_KEY_COMPLIANCE=' "$ENVFILE" | cut -d= -f2)
F=$(grep '^GATEWAY_KEY_FORENSICS=' "$ENVFILE" | cut -d= -f2)
[ -n "$C" ] && [ -n "$F" ] || { echo "no GATEWAY_KEY_* in $ENVFILE"; exit 1; }

send() { # key method -> status
  curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H "x-api-key: $1" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":$3,\"id\":1}" "$RPC"
}
tally=$(mktemp); trap 'rm -f "$tally"' EXIT
count() { printf '%s %s\n' "$1" "$2" >> "$tally"; }   # tenant status, one line per request

end=$(( $(date +%s) + DURATION )); tick=0
echo "playing compliance, forensics and no-key for ${DURATION}s against $RPC"
while [ "$(date +%s)" -lt "$end" ]; do
  tick=$((tick+1))
  count compliance "$(send "$C" eth_getBalance '["0x123463a4B065722E99115D6c222f267d9cABb524","0x1"]')"
  count compliance "$(send "$C" eth_blockNumber '[]')"
  count forensics  "$(send "$F" debug_traceBlockByNumber '["0x1",{"tracer":"callTracer"}]')"
  [ $((tick % 5)) -eq 0 ] && count compliance "$(send "$C" debug_traceBlockByNumber '["0x1",{}]')"
  [ $((tick % 3)) -eq 0 ] && count nokey "$(send '' eth_blockNumber '[]')"
  if [ $((tick % 20)) -eq 0 ]; then for _ in $(seq 1 60); do count forensics "$(send "$F" net_version '[]')"; done; fi
  sleep 0.3
done
echo; sort "$tally" | uniq -c | awk '{printf "  %-12s %-4s %s\n", $2, $3, $1}'
