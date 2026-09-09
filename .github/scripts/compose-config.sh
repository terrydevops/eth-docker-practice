#!/usr/bin/env bash
# Render every compose project without the gitignored .env files. Image pins
# come from devnet/scripts/gen-identities.mjs, the rest are placeholders.
set -euo pipefail
cd "$(dirname "$0")/../.."
envf=$(mktemp); trap 'rm -f "$envf"' EXIT
{
  grep -E '^[A-Z_]+_IMAGE=' devnet/scripts/gen-identities.mjs
  cat <<'EOF'
NET_NAME=ci-devnet
NET_CIDR=172.30.0.0/24
NET_GATEWAY=172.30.0.1
EOF
} > "$envf"

rc=0
render() { # name dir compose-args...; compose output only on failure
  local name=$1 dir=$2 out; shift 2
  printf '%-18s' "$name"
  if out=$(cd "$dir" && docker compose --env-file "$envf" "$@" config -q 2>&1); then
    echo ok
  else
    echo FAIL; echo "$out"; rc=1
  fi
}
for dir in besu geth teku teku-validator lighthouse mev-boost web3signer monitoring; do
  render "$dir" "$dir"
done
# the devnet runs together with the monitoring stack (COMPOSE_FILE in its .env)
render devnet+monitoring devnet -f docker-compose.yml -f ../monitoring/docker-compose.yml
exit "$rc"
