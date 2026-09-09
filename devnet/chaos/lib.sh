#!/usr/bin/env bash
# Shared pieces for the fault-injection runs: steady-state checks, sampling,
# grafana annotations and the results journal. Sourced by the experiment
# scripts, not run on its own.

PROM=${PROM:-http://localhost:9091}
GRAFANA=${GRAFANA:-http://localhost:3001}
GRAFANA_AUTH=${GRAFANA_AUTH:-admin:admin}
BESU_RPC=${BESU_RPC:-http://localhost:8545}
GETH_RPC=${GETH_RPC:-http://localhost:8547}
GATEWAY=${GATEWAY:-http://localhost:8548}
HAPROXY_STATS=${HAPROXY_STATS:-http://localhost:8406/;csv}
PUMBA_IMAGE=${PUMBA_IMAGE:-gaiaadm/pumba:1.2.1}
TC_IMAGE=${TC_IMAGE:-gaiadocker/iproute2}
SAMPLE=${SAMPLE:-15}

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# instant PromQL -> value, empty when no series
q() {
  curl -s --get "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")'
}

head_of() { # rpc url -> block number
  curl -s -m 5 -X POST -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$1" \
    | python3 -c 'import sys,json
try: print(int(json.load(sys.stdin)["result"],16))
except Exception: print("")'
}

ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

# haproxy view of geth1 in the point pool: "STATUS WEIGHT"
geth1_state() {
  curl -s "$HAPROXY_STATS" | awk -F, '$1=="archive_point" && $2=="geth1"{split($18, s, " "); print s[1], $19}'
}

# haproxy check_status for geth1 in the point pool (L7OK, L4TOUT, L4CON, ...)
geth1_check() {
  curl -s "$HAPROXY_STATS" | awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="check_status") c=i} $1=="archive_point" && $2=="geth1"{print $c}'
}

sidecar_lag() { # the sidecar answers 503 above HARD_LAG; node keeps the body, wget does not
  docker exec health-sidecar node -e 'fetch("http://localhost:9998/status").then(r=>r.json()).then(j=>console.log(j.lag)).catch(()=>console.log("-"))' 2>/dev/null
}

# active SLO alerts as "name/state ..." or "-"
alerts() {
  curl -s "$PROM/api/v1/alerts" | python3 -c '
import sys,json
a=[x for x in json.load(sys.stdin)["data"]["alerts"] if x["labels"]["alertname"].startswith("Rpc") or x["labels"]["alertname"]=="SloMeasurementBlind"]
print(" ".join("%s/%s" % (x["labels"]["alertname"], x["state"]) for x in a) or "-")'
}

# one tsv line of everything the hypotheses look at
nz() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "-"; } # never an empty field: tab IFS would swallow it
snapshot() {
  local st; st=$(geth1_state)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ)" "$1" \
    "$(nz "$(head_of "$BESU_RPC")")" "$(nz "$(head_of "$GETH_RPC")")" "$(nz "$(sidecar_lag)")" \
    "$(nz "${st% *}")" "$(nz "${st#* }")" \
    "$(nz "$(q 'slo:rpc_availability:ratio_rate5m')")" \
    "$(nz "$(q 'slo:rpc_error_budget_burn:rate5m')")" \
    "$(nz "$(q 'slo:rpc_error_budget_burn:rate1h')")" \
    "$(nz "$(q 'slo:rpc_error_budget_failed_minutes:30d')")" \
    "$(alerts)"
}
snapshot_header() {
  printf 'time\tphase\tbesu_head\tgeth_head\tlag\tgeth1_status\tgeth1_weight\tavail_5m\tburn_5m\tburn_1h\tspent_min\talerts\n'
}

# steady state: the archive is current, in rotation, and the SLO is quiet
hypothesis() {
  local ok=1 st lag avail burn
  st=$(geth1_state); lag=$(sidecar_lag); avail=$(q 'slo:rpc_availability:ratio_rate5m'); burn=$(q 'slo:rpc_error_budget_burn:rate5m')
  check() { if [ "$2" = 1 ]; then log "  ok    $1"; else log "  FAIL  $1"; ok=0; fi; }
  check "gateway answers a historical read"  "$( [ -n "$(head_of "$GATEWAY")" ] && echo 1 || echo 0)"
  check "availability 5m >= 0.999 ($avail)"   "$(python3 -c "print(1 if float('${avail:-0}')>=0.999 else 0)")"
  check "burn 5m < 1 ($burn)"                 "$(python3 -c "print(1 if float('${burn:-99}')<1 else 0)")"
  check "tip lag <= 2 ($lag)"                 "$(python3 -c "print(1 if int('${lag:-99}')<=2 else 0)")"
  check "geth1 UP at weight 100 ($st)"        "$( [ "$st" = "UP 100" ] && echo 1 || echo 0)"
  check "no SLO alert active ($(alerts))"     "$( [ "$(alerts)" = "-" ] && echo 1 || echo 0)"
  [ "$ok" = 1 ]
}

# the window-free part of the steady state: the archive is current and in
# rotation. used when a previous incident is still inside the SLO windows
hypothesis_core() {
  local ok=1 st lag
  st=$(geth1_state); lag=$(sidecar_lag)
  check() { if [ "$2" = 1 ]; then log "  ok    $1"; else log "  FAIL  $1"; ok=0; fi; }
  check "gateway answers a historical read"  "$( [ -n "$(head_of "$GATEWAY")" ] && echo 1 || echo 0)"
  check "tip lag <= 2 ($lag)"                 "$(python3 -c "print(1 if int('${lag:-99}')<=2 else 0)")"
  check "geth1 UP at weight 100 ($st)"        "$( [ "$st" = "UP 100" ] && echo 1 || echo 0)"
  [ "$ok" = 1 ]
}

# grafana annotation, tagged chaos so both SLO boards show it
annotate() { # text [timeEnd_ms]
  local now; now=$(date +%s000)
  local body="{\"time\":${ANNOTATE_FROM:-$now},\"tags\":[\"chaos\",\"$EXPERIMENT\"],\"text\":\"$1\"}"
  [ -n "${2:-}" ] && body="{\"time\":${ANNOTATE_FROM:-$now},\"timeEnd\":$2,\"tags\":[\"chaos\",\"$EXPERIMENT\"],\"text\":\"$1\"}"
  curl -s -u "$GRAFANA_AUTH" -H 'content-type: application/json' -X POST "$GRAFANA/api/annotations" -d "$body" >/dev/null || true
}

# netem qdisc left behind if pumba was killed: remove it
clear_netem() {
  for c in "$@"; do
    docker run --rm --net="container:$c" --cap-add NET_ADMIN "$TC_IMAGE" tc qdisc del dev eth0 root 2>/dev/null \
      && log "netem removed from $c" || true
  done
}

results_dir() {
  local d
  d="$(dirname "$0")/results/$EXPERIMENT-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$d"; printf '%s\n' "$d"
}
