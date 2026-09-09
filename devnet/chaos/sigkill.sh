#!/usr/bin/env bash
# SIGKILL geth right after a block import, KILLS times, INTERVAL apart.
#
# "During a write" is approximated: the script polls geth's head every
# 200 ms and sends SIGKILL within that window of a head change, i.e. while
# the block and its state are being flushed. geth has no restart policy in
# the compose file, so the script starts it again after RESTART_DELAY,
# standing in for an orchestrator.
#
# Steady state (before and after): the usual six, plus burn 1h < 14.4 so a
# previous incident cannot satisfy the long window of the page.
#
# Prediction per kill:
#   detect   <= 6 s   httpchk inter 2s fall 3 (connection refused fails fast)
#   restart  5-10 s   pebble open, "Unclean shutdown detected", maybe a rewind
#   recover  15-30 s  eth_syncing false, rise 2, back to UP 100 with the
#                     L7 check passing (haproxy keeps showing UP until fall 3
#                     completes, so UP alone is not recovery)
#   budget   0.3-0.5 min per kill (5-10 failed probes)
# Prediction for the series: one kill never pages (1h window stays under
# 14.4x); four or more kills inside an hour do.
#
# Blast radius: pair B only. lighthouse logs engine errors while geth is
# down; the validating pair is untouched.
# Rollback: geth is started again after every kill and on Ctrl-C.
#
# Usage:
#   ./sigkill.sh                         one kill, restarted at once (the orchestrator model)
#   IP_CHANGE=1 ./sigkill.sh             the restart lands on a new address
#   KILLS=5 INTERVAL=60 ./sigkill.sh     crash loop: the page is expected around the 4th kill
#   NO_RESTART=1 ./sigkill.sh            no orchestrator: geth stays down for RECOVER_MAX
#                                        seconds (page expected after ~2.5 min), then is started
#   ALLOW_DIRTY_WINDOW=1                 run while a previous incident is still in the 1h window
set -euo pipefail
export EXPERIMENT=sigkill
KILLS=${KILLS:-1}
INTERVAL=${INTERVAL:-120}
RESTART_DELAY=${RESTART_DELAY:-0}
RECOVER_MAX=${RECOVER_MAX:-180}
ALLOW_DIRTY_WINDOW=${ALLOW_DIRTY_WINDOW:-0}   # run even if the 1h window still holds a previous incident
IP_CHANGE=${IP_CHANGE:-0}   # take geth's freed address with a placeholder so the restart lands on a new IP
NO_RESTART=${NO_RESTART:-0} # leave geth down until RECOVER_MAX, then start it: what a crash costs without an orchestrator
DRY_RUN=${DRY_RUN:-0}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

cleanup() { docker rm -f chaos-ip-hog >/dev/null 2>&1 || true; docker start geth >/dev/null 2>&1 || true; }
trap cleanup INT TERM

burn1h_ok() { python3 -c "print(1 if float('$(q 'slo:rpc_error_budget_burn:rate1h')' or 99)<14.4 else 0)"; }

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: would SIGKILL geth $KILLS time(s), $INTERVAL s apart, $( [ "$NO_RESTART" = 1 ] && echo "no restart for ${RECOVER_MAX}s" || echo "restart after ${RESTART_DELAY}s")$( [ "$IP_CHANGE" = 1 ] && echo ", new address")"
  log "steady state now:"; hypothesis; [ "$(burn1h_ok)" = 1 ] && log "  ok    burn 1h < 14.4" || log "  FAIL  burn 1h < 14.4 (a previous incident is still in the window)"
  exit 0
fi

out=$(results_dir); log "results -> $out"
window=clean
if [ "$ALLOW_DIRTY_WINDOW" = 1 ]; then
  window=dirty; log "steady state before (dirty window acknowledged: only the window-free checks are required)"
  hypothesis_core || { log "archive not current or not in rotation, not injecting"; exit 1; }
  log "  full steady state, for the record:"; hypothesis || true
else
  log "steady state before"; hypothesis || { log "steady state not met, not injecting"; exit 1; }
  [ "$(burn1h_ok)" = 1 ] || { log "burn 1h still over 14.4 from a previous incident, wait for the window to clear (or ALLOW_DIRTY_WINDOW=1)"; exit 1; }
fi
spent_before=$(q 'slo:rpc_error_budget_failed_minutes:30d')
start=$(date +%s); export ANNOTATE_FROM=${start}000
snapshot_header > "$out/samples.tsv"; snapshot before >> "$out/samples.tsv"
annotate "sigkill geth x$KILLS"
printf 'kill\thead\tdetect_s\trestart_s\trecover_s\tunclean\trewound\n' > "$out/kills.tsv"

ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
for n in $(seq 1 "$KILLS"); do
  # wait for the next block to land, then kill inside the flush window
  h0=$(head_of "$GETH_RPC"); h=$h0; i=0
  while [ "$h" = "$h0" ] && [ $i -lt 100 ]; do sleep 0.2; h=$(head_of "$GETH_RPC"); i=$((i+1)); done
  ip_before=$(ip_of geth)
  t_kill=$(ms); docker kill -s KILL geth >/dev/null
  log "kill $n at head $h"
  # take geth's old address explicitly: a placeholder without --ip gets the lowest free one instead
  [ "$IP_CHANGE" = 1 ] && docker run -d --rm --name chaos-ip-hog --network eth-devnet-network --ip "$ip_before" alpine sleep 300 >/dev/null
  if [ "$NO_RESTART" = 1 ]; then
    log "  no restart: geth stays down for ${RECOVER_MAX}s"
  else
    [ "$RESTART_DELAY" != 0 ] && sleep "$RESTART_DELAY"
    docker start geth >/dev/null
    log "  geth address $ip_before -> $(ip_of geth)"
  fi
  t_down=""; t_http=""; t_up=""; stable=0; never_down=0
  while :; do
    st=$(geth1_state); chk=$(geth1_check); now=$(ms)
    [ -z "$t_down" ] && { [ "${st% *}" = DOWN ] || [ "$chk" != L7OK ]; } && t_down=$now
    [ -z "$t_http" ] && [ -n "$(head_of "$GETH_RPC")" ] && t_http=$now
    if [ -n "$t_http" ] && [ "$st" = "UP 100" ] && [ "$chk" = L7OK ]; then stable=$((stable+1)); else stable=0; fi
    if [ "$stable" -ge 10 ]; then
      if [ -n "$t_down" ]; then t_up=$((now - 10000)); else never_down=1; fi
      break
    fi
    [ $(( (now - t_kill) / 1000 )) -ge "$RECOVER_MAX" ] && break
    sleep 1
  done
  if [ "$NO_RESTART" = 1 ]; then
    log "  alerts while down: $(alerts)"; docker start geth >/dev/null; log "  geth started after ${RECOVER_MAX}s ($ip_before -> $(ip_of geth))"
    i=0; until [ "$(geth1_state)" = "UP 100" ] && [ "$(geth1_check)" = L7OK ] || [ $i -ge 60 ]; do sleep 1; i=$((i+1)); done
    t_up=$(ms); log "  back in rotation $(sec "$t_up")s after the kill"
  fi
  unclean=$(docker logs geth --since "$(( (t_kill/1000) - 1 ))" 2>&1 | grep -c 'Unclean shutdown' || true)
  rewound=$(docker logs geth --since "$(( (t_kill/1000) - 1 ))" 2>&1 | grep -iE 'rewound|rewind|repair|head state missing' | head -1 | sed 's/^.*\] //' || true)
  sec() { [ -n "$1" ] && printf '%.1f' "$(python3 -c "print(($1-$t_kill)/1000)")" || printf 'none'; }
  if [ "$never_down" = 1 ]; then d="never left rotation"; r="0"; else d="$(sec "$t_down")"; r="$(sec "$t_up")"; fi
  log "  detect ${d}s  rpc back $(sec "$t_http")s  recovered ${r}s  unclean=$unclean  ${rewound:-no rewind line}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$h" "$d" "$(sec "$t_http")" "$r" "$unclean" "${rewound:--}" >> "$out/kills.tsv"
  snapshot "after-kill-$n" >> "$out/samples.tsv"
  [ "$n" -lt "$KILLS" ] && sleep "$INTERVAL"
done

docker rm -f chaos-ip-hog >/dev/null 2>&1 || true
annotate "sigkill end" "$(date +%s000)"
sleep 30; snapshot after >> "$out/samples.tsv"
spent_after=$(q 'slo:rpc_error_budget_failed_minutes:30d')
log "steady state after"; hypothesis && after=PASS || after=FAIL
{
  echo "# sigkill geth x$KILLS, interval ${INTERVAL}s, $(date -u +%F)"
  echo
  echo "| kill | head | detect s | rpc back s | recovered s | unclean shutdown | rewind |"
  echo "|---|---|---|---|---|---|---|"
  tail -n +2 "$out/kills.tsv" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,($6>0?"yes":"no"),$7}'
  echo
  echo "predicted per kill: detect <= 6 s, recovered 15-30 s, 0.3-0.5 min budget"
  echo "budget spent: $(python3 -c "print(round(float('${spent_after:-0}')-float('${spent_before:-0}'),2))") min"
  echo "alerts seen: $(alerts)"
  echo "1h window at start: $window$( [ "$window" = dirty ] && echo " (previous incident inside it, page result not counted)")"
  echo "steady state after: $after"
} | tee "$out/summary.md"
