#!/usr/bin/env bash
# Partition the archive pair from the validating pair for DURATION, then let
# it come back.
#
# What is cut: lighthouse <-> teku (CL gossip, this is what freezes geth)
# and geth <-> besu (EL p2p), both directions. One direction is not enough:
# TCP keeps delivering the sender's unacked window, and a block is small.
# The rules on teku and besu match one destination IP each, so the
# validating pair's other traffic is untouched. The health-sidecar and the
# prober keep their HTTP paths, so the stale-but-correct phase is visible.
#
# Steady state (checked before and after): gateway answers, availability 5m
# >= 0.999, burn 5m < 1, tip lag <= 2, geth1 UP at weight 100, no SLO alert.
#
# Prediction for 10m (first run 2026-09-09 in brackets):
#   T+0:30  lag 2   -> geth1 weight 50, probes still 100% (stale but correct)  [T+0:35]
#   T+2:00  lag 10  -> geth1 DOWN, every request 503                            [T+2:10]
#   T+4:40  availability 5m below 0.5 (a 5 min window takes 2.5 min to get there) [T+4:50]
#   T+5:00  RpcAvailabilityFastBurn firing (5m and 1h > 14.4, then for: 2m)     [T+5:10]
#   T+10:00 netem removed; lighthouse and teku have to re-peer before geth moves
#   T+10:30 geth1 UP 100 again                                                   [T+13:56, re-peering took 4 min]
#   budget spent: about 8.5 min of 43.2                                          [11.7]
#   RpcAvailabilitySlowBurn ticket around T+19, after recovery                   [T+19:25]
#
# Blast radius: pair B only; block production stays on pair A.
# Rollback: pumba removes the netem when the duration ends; clear_netem
# covers a killed pumba. Ctrl-C triggers the same cleanup.
set -euo pipefail
export EXPERIMENT=partition
DURATION=${DURATION:-10m}
RECOVER=${RECOVER:-6m}
DRY_RUN=${DRY_RUN:-0}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

TEKU_IP=$(ip_of teku); BESU_IP=$(ip_of besu); LH_IP=$(ip_of lighthouse); GETH_IP=$(ip_of geth)
[ -n "$TEKU_IP" ] && [ -n "$BESU_IP" ] && [ -n "$LH_IP" ] && [ -n "$GETH_IP" ] || { log "a node container is not running"; exit 1; }
# container:target-ip, one pumba each
CUTS="lighthouse:$TEKU_IP teku:$LH_IP geth:$BESU_IP besu:$GETH_IP"
cut_cmd() { # container target -> the pumba command line
  printf 'docker run -d --rm --name chaos-partition-%s -v /var/run/docker.sock:/var/run/docker.sock %s netem --duration %s --tc-image %s --target %s loss --percent 100 %s' \
    "$1" "$PUMBA_IMAGE" "$DURATION" "$TC_IMAGE" "$2" "$1"
}
to_s() { python3 -c "import sys;v=sys.argv[1];print(int(v[:-1])*{'s':1,'m':60,'h':3600}[v[-1]])" "$1"; }
TOTAL=$(( $(to_s "$DURATION") + $(to_s "$RECOVER") ))

cleanup() {
  docker rm -f chaos-partition-lighthouse chaos-partition-teku chaos-partition-geth chaos-partition-besu >/dev/null 2>&1 || true
  clear_netem lighthouse teku geth besu
}
trap cleanup INT TERM

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: would cut both directions of lighthouse<->teku and geth<->besu for $DURATION, then watch $RECOVER"
  for c in $CUTS; do log "$(cut_cmd "${c%%:*}" "${c#*:}")"; done
  log "steady state now:"; hypothesis; exit 0
fi

out=$(results_dir); log "results -> $out"
log "steady state before"; hypothesis || { log "steady state not met, not injecting"; exit 1; }
start=$(date +%s); export ANNOTATE_FROM=${start}000

snapshot_header > "$out/samples.tsv"; snapshot before >> "$out/samples.tsv"
annotate "partition start: lighthouse<->teku and geth<->besu cut for $DURATION"
for c in $CUTS; do eval "$(cut_cmd "${c%%:*}" "${c#*:}")" >/dev/null; done
log "injected; sampling every ${SAMPLE}s for ${TOTAL}s"

while :; do
  now=$(date +%s); el=$((now - start))
  phase=during; [ "$el" -ge "$(to_s "$DURATION")" ] && phase=recover
  line=$(snapshot "$phase"); printf '%s\n' "$line" >> "$out/samples.tsv"
  IFS=$'\t' read -r _ _ bh gh lag st w av _ _ _ al <<< "$line"
  log "$phase t+${el}s besu=$bh geth=$gh lag=$lag geth1=$st/$w avail5m=$av alerts=$al"
  [ "$el" -ge "$TOTAL" ] && break
  sleep "$SAMPLE"
done

docker ps --format '{{.Names}}' | grep -q '^chaos-partition-' && { log "pumba still running, forcing cleanup"; cleanup; }
clear_netem lighthouse teku geth besu
annotate "partition end" "$(date +%s000)"
log "steady state after (the slow-burn ticket may still be active for ~30 min, its windows are long)"
hypothesis && after=PASS || after=FAIL
# the table comes from prometheus, not from the 15 s samples; the slow-burn
# ticket fires around T+19, so run this once more after that for a full table
{ python3 "$(dirname "$0")/summary.py" "$out"; echo; echo "steady state after: $after"; echo "samples: samples.tsv"; } | tee "$out/summary.md"
