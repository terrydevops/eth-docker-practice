#!/usr/bin/env bash
# Stop every fault this directory can inject and put the archive pair back:
# pumba containers, netem left on the interfaces, a stopped geth, the
# address placeholder. Safe to run at any time, also when nothing is running.
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

log "stopping injectors"
docker ps -a --format '{{.Names}}' | grep -E '^chaos-' | xargs -r docker rm -f >/dev/null 2>&1 && log "  chaos containers removed" || log "  no chaos containers"
clear_netem lighthouse teku geth besu
[ "$(docker inspect -f '{{.State.Running}}' geth 2>/dev/null)" = true ] || { docker start geth >/dev/null 2>&1 && log "  geth started"; }
# after a partition the archive pair has to re-peer before geth catches up.
# a healed partition can leave a half-open libp2p connection (lighthouse
# keeps a peer teku no longer has) and then nothing re-dials; restarting
# teku is the one action seen to fix it (validators miss a slot or two)
recovered() { [ "$(geth1_state)" = "UP 100" ] && [ "$(geth1_check)" = L7OK ]; }
wait_for() { local n=$1 i=0; until recovered || [ $i -ge "$n" ]; do [ $((i % 15)) -eq 0 ] && log "  waiting: lag=$(sidecar_lag) geth1=$(geth1_state) $(geth1_check)"; sleep 1; i=$((i+1)); done; }
wait_for 60
if ! recovered; then
  log "  archive pair did not re-peer in 60 s, restarting teku"; docker restart teku >/dev/null; wait_for 120
fi
log "gateway backend geth1: $(geth1_state) $(geth1_check)"
log "steady state:"; hypothesis_core
