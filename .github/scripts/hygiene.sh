#!/usr/bin/env bash
# The repo is public and English only, with no assistant attribution.
# Checks tracked text files; binaries (screenshots) are skipped.
set -euo pipefail
cd "$(dirname "$0")/../.."

rc=0
check() { # name grep-args...
  local name=$1 out; shift
  printf '%-10s' "$name"
  if out=$(git grep -nI "$@"); then
    echo FAIL; echo "$out"; rc=1
  else
    echo ok
  fi
}
check cjk -P '[\x{4e00}-\x{9fff}\x{3000}-\x{303f}\x{ff00}-\x{ffef}]'
# brackets keep this script from matching itself
check names -iE 'cl[a]ude|co-a[u]thored-by'
exit "$rc"
