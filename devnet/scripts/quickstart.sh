#!/usr/bin/env bash
# One-command bring-up and verification of the devnet, for macOS and Ubuntu.
#
#   ./scripts/quickstart.sh          check prereqs, generate identities, run
#                                    the genesis ceremony, start everything,
#                                    wait for blocks, send traffic, verify
#   ./scripts/quickstart.sh clean    destroy containers, volumes and all
#                                    generated state
#
# Requires: docker (with compose v2), curl, python3. node is optional - the
# identity generator falls back to a docker container.
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE_FILES="docker-compose.yml:../monitoring/docker-compose.yml"

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$1"; exit 1; }

if [ "${1:-}" = "clean" ]; then
  say "destroying containers, volumes and generated state"
  COMPOSE_FILE="$COMPOSE_FILES" docker compose down -v --remove-orphans 2>/dev/null || true
  rm -f config/genesis.ssz
  echo "clean."
  exit 0
fi

say "1/7 prerequisites"
command -v docker >/dev/null 2>&1 || fail "docker not found - install Docker (https://docs.docker.com/engine/install/)"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 not found - install the compose plugin"
docker info >/dev/null 2>&1 || fail "docker daemon not reachable - is Docker running?"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
echo "docker, compose v2, curl, python3: ok"

say "2/7 identities and .env"
if [ -f .env ] && [ -f config/genesis.ssz ]; then
  echo "existing chain detected (.env + genesis.ssz) - reusing it."
  echo "for a fresh chain run: ./scripts/quickstart.sh clean"
else
  if command -v node >/dev/null 2>&1; then
    node scripts/gen-identities.mjs >/dev/null
  else
    echo "node not installed - generating identities in a container"
    docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/w -w /w \
      node:26.5.0-alpine node scripts/gen-identities.mjs >/dev/null
  fi
  echo "identities, jwt secrets and .env generated"

  say "3/7 genesis ceremony"
  ./scripts/genesis.sh
fi

say "4/7 starting the stack"
docker compose up -d
echo "containers started (validating pair, archive pair, gateway, prober, monitoring)"

say "5/7 waiting for the chain (genesis +90s, then blocks)"
rpc_head() { curl -s -m 5 -X POST -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$1" 2>/dev/null \
  | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null || echo ""; }
deadline=$((SECONDS + 480))
while [ $SECONDS -lt $deadline ]; do
  bh=$(rpc_head http://localhost:8545)
  gh=$(rpc_head http://localhost:8547)
  printf '  validating head: %-6s archive head: %-6s\r' "${bh:-...}" "${gh:-...}"
  if [ -n "$bh" ] && [ "$bh" -ge 5 ] && [ -n "$gh" ] && [ "$gh" -ge 3 ]; then
    printf '\n'; echo "chain is live and the archive node is following"; break
  fi
  sleep 10
done
[ -n "${gh:-}" ] && [ "${gh:-0}" -ge 3 ] || fail "chain did not come up within 8 minutes - check: docker compose logs besu teku lighthouse geth"

say "6/7 sending traffic (so historical state differs across heights)"
./scripts/send-traffic.sh | tail -1

say "7/7 verification"
./scripts/verify-archive.sh
./scripts/test-rpc.sh

say "done"
cat <<EOF
Grafana:      http://localhost:3001   (dashboards: Devnet, Machine, Containers, Logs, Clients)
Prometheus:   http://localhost:9091   (19 alerts across machine/container/chain/SLO layers)
Archive RPC:  http://localhost:8548   (gateway - the SLO measurement point)

To watch an SLO breach: docker compose stop geth   (fast-burn pages in ~3 min)
To tear down:           ./scripts/quickstart.sh clean
EOF
