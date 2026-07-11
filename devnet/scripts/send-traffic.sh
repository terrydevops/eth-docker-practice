#!/usr/bin/env bash
# Sends a handful of value transfers from the prefunded dev account so the
# chain contains real state transitions  -  making historical balance queries
# against the archive node meaningfully different across heights.
#
# Uses foundry's `cast` in a one-shot container (no local toolchain needed).
set -euo pipefail

RPC=${1:-http://besu:8545}
NETWORK=archive-node-challenge_default
# Prefunded dev account (devnet-only key, see execution/genesis.json alloc)
# well-known public interop test key, funded in genesis, devnet only
KEY=2e0834786285daccd064ca17f1654f67b4aef298acbb82cef9ec422fb4975622
FOUNDRY_IMAGE=ghcr.io/foundry-rs/foundry:stable

for i in 1 2 3 4 5; do
  TO=$(printf '0x%040x' "$i")
  echo "-> sending 0.${i} ETH to $TO"
  docker run --rm --network "$NETWORK" "$FOUNDRY_IMAGE" \
    "cast send $TO --value 0.${i}ether --private-key $KEY --rpc-url $RPC --legacy" \
    | grep -E 'status|blockNumber' || true
  sleep 7   # ~one slot so transfers land in different blocks
done
echo "done  -  balances now differ across historical heights"
