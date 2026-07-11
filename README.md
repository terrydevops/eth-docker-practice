# eth-docker-practice

Docker compose stacks for Ethereum nodes and validators. One directory per
component, deployed independently, joined by a shared bridge network.

```
besu/ or geth/  <--engine api-->  teku/ or lighthouse/  <--rest-->  teku-validator/
     EL                                CL                                VC
                                        |                                 |
                                   mev-boost/                       web3signer/ + postgres
```

## Layout

| dir | role | notes |
|---|---|---|
| besu/ | execution client | bonsai + snap sync |
| geth/ | execution client | version pinned in .env |
| teku/ | consensus client | checkpoint sync, mev wired |
| lighthouse/ | consensus client | alternative CL |
| teku-validator/ | validator client | signs via web3signer by default |
| web3signer/ | remote signer | postgres slashing db, flyway migrations |
| mev-boost/ | mev sidecar | relay list per network in .env |

## Why this shape

- each component has its own compose project, .env and data dir. EL upgrades
  never touch the VC. components talk over one named bridge network.
- EL and CL both come in two flavours with the same interface, so pairs can
  be mixed: besu+teku primary, geth+lighthouse standby, each synced
  independently.
- validator keys are not on the validator client. web3signer holds them,
  slashing protection lives in postgres. several web3signer instances can
  share one slashing db - db locking makes sure a key signs only once.
- metrics on for every component, http allowlists closed by default.

## Quickstart (holesky)

```bash
# per component: copy env template and review
cd besu && cp .env.example .env && cd ..
cd teku && cp .env.example .env && cd ..

# one jwt secret per EL/CL pair
openssl rand -hex 32 | tr -d "\n" > jwtsecret.hex
cp jwtsecret.hex besu/data/ && cp jwtsecret.hex teku/data/

# EL first, then CL
(cd besu && docker compose up -d)
(cd teku && docker compose up -d)
```

Validator setup and day-2 procedures (deposit keys, voluntary exit,
slashing db migration, api checks): see [docs/runbook.md](docs/runbook.md).

## Notes

- change the placeholder postgres credentials and set your own
  VALIDATORS_FEE_RECIPIENT before starting anything.
- jwt secrets and keystores are gitignored, only templates are committed.
