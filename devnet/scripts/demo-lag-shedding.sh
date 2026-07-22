#!/usr/bin/env bash
# Demonstrates the gateway shedding traffic as the archive node falls behind.
#
# The health-sidecar compares geth's head to besu's and drives haproxy's
# agent-check, which sets geth's weight: 100% when current, 50% when drifting
# (>= SOFT_LAG), down when too far behind (>= HARD_LAG). Rather than actually
# breaking the chain, this injects a synthetic lag via the sidecar's demo
# override and watches the weight react.
set -uo pipefail

STATS="${STATS_URL:-http://localhost:8406/;csv}"
show() {   # print geth1's state+weight in both pools (cols: 1 pxname, 18 status, 19 weight, 63 agent_status)
  curl -s "$STATS" \
    | awk -F, '$2=="geth1"{printf "    %-14s status=%-7s weight=%-4s agent=%s\n", $1, $18, $19, $63}'
}
inject() { docker exec health-sidecar wget -qO- "http://localhost:9998/override?lag=$1" >/dev/null 2>&1; }
clear_override() { docker exec health-sidecar wget -qO- "http://localhost:9998/override?clear=1" >/dev/null 2>&1; }

echo "== baseline (measured lag, no override) =="; show
for L in 0 3 15 3 0; do
  echo; echo "== inject lag = $L blocks =="; inject "$L"; sleep 4; show
done
echo; echo "== clear override (back to measured lag) =="; clear_override; sleep 4; show
