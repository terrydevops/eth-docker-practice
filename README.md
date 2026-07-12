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

Client definitions live at the top level and are shared. Each network
directory selects which of them to run (via `COMPOSE_FILE`) and holds that
network's config. Monitoring is a shared stack included by each environment.

**Clients (shared compose):**

| dir | role |
|---|---|
| besu/ | execution client |
| geth/ | execution client |
| teku/ | consensus client |
| lighthouse/ | consensus client |
| teku-validator/ | validator client (signs via web3signer) |
| web3signer/ | remote signer + postgres slashing db |
| mev-boost/ | mev sidecar |

**Environments:**

| dir | what it starts | how |
|---|---|---|
| holesky-network/ | besu + teku + teku-validator + web3signer + monitoring on Holesky | `cd holesky-network && docker compose up -d` |
| mainnet/ | same stack on mainnet | `cd mainnet && docker compose up -d` |
| devnet/ | local PoS net (besu+teku+prysm-vc validating, geth+lighthouse archive) + monitoring | `cd devnet && make setup genesis up` |

**Shared:**

| dir | what |
|---|---|
| monitoring/ | full observability, included by each environment: metrics (prometheus + node-exporter + cadvisor), logs (loki + promtail), grafana dashboards (Clients, Devnet, Machine, Containers, Logs) |
| docs/ | day-2 runbook |

Each environment picks its components with `COMPOSE_FILE` in its `.env`, so
the client composes are never duplicated. All images are pinned to current
versions.


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
