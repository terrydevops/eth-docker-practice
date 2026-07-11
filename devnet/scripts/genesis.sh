#!/usr/bin/env bash
# one-time genesis ceremony. rerunning silently forks the chain, so it refuses.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f config/genesis.ssz ]; then
  echo "config/genesis.ssz exists - refusing to regenerate. make clean first."
  exit 0
fi
source .env
# always start from the pristine base - a previous ceremony writes its
# timestamp into genesis.json, and reusing that silently pins the old genesis time
cp execution/genesis.base.json execution/genesis.json
docker run --rm \
  -v "$PWD/config:/config" \
  -v "$PWD/execution:/execution" \
  "$PRYSMCTL_IMAGE" \
  testnet generate-genesis \
  --fork=electra \
  --num-validators=64 \
  --genesis-time-delay=90 \
  --chain-config-file=/config/cl-config.yaml \
  --geth-genesis-json-in=/execution/genesis.json \
  --geth-genesis-json-out=/execution/genesis.json \
  --output-ssz=/config/genesis.ssz
# lighthouse testnet-dir wants these two alongside config/genesis
cp config/cl-config.yaml config/config.yaml
echo 0 > config/deposit_contract_block.txt
# derive the besu flavour of the EL genesis: explicit consensus mechanism,
# electra system-contract addresses, minus geth-only fields
python3 - <<'PY'
import json
g=json.load(open('execution/genesis.json'))
b=json.loads(json.dumps(g))
b['config'].pop('blobSchedule',None)
b['config'].pop('terminalTotalDifficultyPassed',None)
b.pop('slotNumber',None)
b['config']['ethash']={}
b['config']['withdrawalRequestContractAddress']='0x00000961Ef480Eb55e80D19ad83579A64c007002'
b['config']['consolidationRequestContractAddress']='0x0000BBdDc7CE488642fb579F8B00f3a590007251'
json.dump(b,open('config/besu-genesis.json','w'),indent=2)
print('besu-genesis derived')
PY
echo "genesis written (chain starts ~90s after this moment once nodes are up)"
