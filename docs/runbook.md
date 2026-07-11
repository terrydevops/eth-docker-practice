# Operations Runbook

Key generation, jwt setup, validator lifecycle, slashing db migration, api checks.

## Deposit keystore

```bash
# mainnet
./deposit new-mnemonic --chain mainnet --eth1_withdrawal_address <your_withdrawal_address> --num_validators 10

# testnet holesky
./deposit new-mnemonic --chain holesky --eth1_withdrawal_address <your_withdrawal_address> --num_validators 10
```

generated keys:

```bash
validator_keys/
├── deposit_data-1694112887.json
├── keystore-m_12381_3600_0_0_0-1694112883.json
├── keystore-m_12381_3600_1_0_0-1694112884.json
└── keystore-m_12381_3600_2_0_0-1694112885.json
```

batch generate password file

```bash
# sudo apt install rename
rename 's/\.json$/.txt/' *.json
sed -i 's/.*/<your_keystore_password>/' *.txt
```

## JWT Secret

```bash
openssl rand -hex 32 | tr -d "\n" > jwtsecret.hex

cp jwtsecret.hex besu/data/
cp jwtsecret.hex teku/data/
```

### validators

```bash
cp validator_keys/* teku-validator/data/validators/keys/
# need generate password file
cp validator_passwords/* teku-validator/data/validators/passwords/
```

## Besu

### API

> https://besu.hyperledger.org/public-networks/reference/api

```bash
# eth_chainId
curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' host:8545 | jq

# eth_syncing
curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' host:8545 | jq
```

## Teku

### state.ssz

```bash
curl -sS -o state.ssz -H 'Accept: application/octet-stream' https://checkpoint-sync.holesky.ethpandaops.io/eth/v2/debug/beacon/states/finalized
```

### API

> https://consensys.github.io/teku/

```bash
# count peers
curl -sS http://teku:5051/eth/v1/node/peers | jq '.data | group_by(.direction)[] | {direction: .[0].direction, count: length}' | jq

# proposers data
curl -sS http://teku:5051/teku/v1/beacon/proposers_data | jq
```

## Teku validator

### API

> https://consensys.github.io/teku/

### Exit

```bash
NET_GATEWAY=10.222.1.1
EXIT_KEYS=0x1..,0x2..

sudo docker compose exec teku-validator /opt/teku/bin/teku voluntary-exit \
    --beacon-node-api-endpoint=http://${NET_GATEWAY}:5051 \
    --validator-public-keys=${EXIT_KEYS}

# or via web3signer
sudo docker compose exec teku-validator /opt/teku/bin/teku voluntary-exit \
    --beacon-node-api-endpoint=http://${NET_GATEWAY}:5051 \
    --validators-external-signer-url=http://${NET_GATEWAY}:29000 \
    --validators-external-signer-public-keys=${EXIT_KEYS}
```

## Web3signer

### migration

#### flyway.conf

```ini
# change hostname
flyway.url=jdbc:postgresql://postgres/web3signer
flyway.user=postgres
flyway.password=postgres
```

#### migrate

```bash
git clone https://github.com/Consensys/web3signer.git
git checkout 23.9.1

sudo docker pull redgate/flyway

SQL_PATH=/path/to/web3signer/slashing-protection/src/main/resources/migrations/postgresql
CONF_PATH=$(pwd)/flyway
sudo docker run --rm -v "${SQL_PATH}:/flyway/sql" -v "${CONF_PATH}:/flyway/conf" redgate/flyway migrate
```

### API

> https://consensys.github.io/web3signer/

```bash
# healthcheck
curl -sS http://web3signer:29000/healthcheck | jq

# list public keys
curl -sS http://web3signer:29000/api/v1/eth2/publicKeys | jq

# keystores
curl -sS http://web3signer:29000/eth/v1/keystores | jq
curl -sS http://web3signer:29000/eth/v1/keystores | jq -r '.data | map(.validating_pubkey) | join(",")'
```

### Note

> Multiple Web3Signer instances can connect to the same slashing protection database. Database locking ensures that if Web3signer instances load the same keys, only one Web3signer instance actually signs.
