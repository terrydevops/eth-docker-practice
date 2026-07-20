#!/usr/bin/env bash
# One-click pause for the local devnet + reclaim disk space.
#
#   ./pause.sh            stop devnet containers, prune dangling images and
#                         unused build cache; data volumes are kept, so
#                         resume with:  docker compose -p devnet start
#   ./pause.sh --deep     full teardown: remove devnet containers, networks,
#                         volumes and images, prune ALL build cache; resume
#                         from a fresh chain:  cd devnet && make setup genesis up
#   ./pause.sh --dry-run  print what would run without changing anything
#
# Scope: only containers labelled with compose project "devnet". Other
# stacks on this machine (w3craft, waoowaoo, ...) are never touched.

set -euo pipefail

PROJECT=devnet
DEEP=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--deep] [--dry-run]" >&2; exit 1 ;;
  esac
done

run() {
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

echo "== docker disk usage (before) =="
docker system df
echo

CONTAINERS=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
if [ -z "$CONTAINERS" ]; then
  echo "no '$PROJECT' containers found - nothing to pause"
else
  # capture the image list before containers disappear (--deep needs it)
  IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
             --format '{{.Image}}' | sort -u)

  if [ "$DEEP" = 1 ]; then
    echo "== deep teardown: containers, networks, volumes =="
    run docker compose -p "$PROJECT" down --volumes --remove-orphans
    echo
    echo "== removing $PROJECT images =="
    for img in $IMAGES; do
      run docker rmi "$img" || true   # skip images still used elsewhere
    done
  else
    echo "== stopping $PROJECT containers =="
    RUNNING=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")
    if [ -n "$RUNNING" ]; then
      run docker stop $RUNNING
    else
      echo "already stopped"
    fi
  fi
fi
echo

echo "== pruning docker caches =="
run docker image prune -f
if [ "$DEEP" = 1 ]; then
  run docker builder prune -af
else
  run docker builder prune -f
fi
echo

echo "== docker disk usage (after) =="
docker system df
echo

if [ "$DEEP" = 1 ]; then
  echo "devnet fully removed. resume with a fresh chain:"
  echo "  cd devnet && make setup && make genesis && make up"
else
  echo "devnet paused (data volumes kept). resume with:"
  echo "  docker compose -p $PROJECT start"
  echo "reclaim everything devnet-related instead:  ./pause.sh --deep"
fi
