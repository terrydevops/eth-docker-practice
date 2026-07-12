# mainnet

Runs the validator stack (besu + teku + teku-validator + web3signer) plus
monitoring on mainnet, using the shared client composes at the repo root.

```bash
cp .env.example .env      # then set VALIDATORS_FEE_RECIPIENT and postgres creds
docker compose up -d
```

Which components start is controlled by `COMPOSE_FILE` in `.env`.
