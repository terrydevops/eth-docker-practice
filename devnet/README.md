# devnet

A self-contained local Ethereum PoS network for testing operations against a
chain you fully control - no checkpoint sync, no public testnet, blocks in
seconds. Two client-diverse pairs:

```
validating pair                       archive pair
+------------------+                  +-------------------+
| besu (EL)  :8545 |  <-- EL p2p -->  | geth (EL)  :8547  |
| teku (CL)  :5051 |  <-- CL p2p -->  | lighthouse (CL)   |
| prysm vc, 64 val |                  |  --gcmode=archive |
+------------------+                  +-------------------+
  produces blocks                      follows, keeps full history
```

The validating pair produces blocks continuously; the archive pair follows
and retains all historical state, queryable on port 8547. Client diversity
across the pairs is intentional: a consensus bug in one client cannot take
out both.

## Run

```bash
make setup     # node identities, jwt secrets, .env (generated, not committed)
make genesis   # one-time genesis ceremony (refuses to rerun)
make up        # start both pairs
make status    # heads of both ELs + consensus slot
make traffic   # send transfers so historical state differs across heights
make verify    # prove the archive property
make clean     # full reset
```

Blocks start ~90s after genesis.

## Inspect archive queries

`make verify` asserts what makes this an archive node, not a pruned one:

1. archive head follows the validating head
2. `eth_getBalance(account, height)` succeeds at any past height (a pruned
   node returns `missing trie node` beyond its horizon); after `make traffic`
   the balances differ across heights - real point-in-time state
3. `debug_traceBlockByNumber` works on old blocks
4. the geth container runs `--gcmode=archive --state.scheme=hash --syncmode=full --history.transactions=0`

Manual check (funded account balance drops as it spends):

```bash
for b in 0x1 0x58 0x5e; do
  curl -s -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"0x123463a4B065722E99115D6c222f267d9cABb524\",\"$b\"],\"id\":1}" \
    http://localhost:8547
done
```


## Monitoring

`make up` also starts the shared observability stack. It covers four layers,
so a problem can be traced from the host down to a single log line:

| layer | collector | what |
|---|---|---|
| business (chain) | Prometheus | besu, teku, geth, lighthouse, prysm-validator metrics + archive alerts |
| machine (host) | node-exporter | cpu, memory, disk, filesystem, network of the host |
| container | cAdvisor | per-container cpu / memory / network |
| logs | Loki + Promtail | every container's stdout/stderr, searchable in Grafana |

```bash
make monitor   # print the URLs + a live tip-lag reading
```

- Grafana: http://localhost:3001 (anonymous viewer enabled). Dashboard folders:
  - **Clients** - official per-client dashboards (Besu, Geth, Teku, Lighthouse).
  - **Devnet** - archive dashboard (validating vs archive block height, tip
    lag, CL peers) and validator dashboard (64 validators, attestations,
    proposals).
  - **Machine** - host cpu / memory / disk / network (node-exporter).
  - **Containers** - per-container cpu / memory / network (cAdvisor).
  - **Logs** - log volume, error/warn rate, and a live log viewer with a
    per-service filter and free-text search, backed by Loki.
- Prometheus: http://localhost:9091 - scrapes the five node jobs plus
  node-exporter and cadvisor.
- Loki has no host port: Grafana queries it over the internal network. Promtail
  discovers containers via the docker socket and is scoped (by network) to this
  stack, so it does not ingest unrelated containers on a shared host.

Alerts (`monitoring/alerts.yml`), each verified to fire:

| alert | condition |
|---|---|
| ArchiveNodeLagging | archive head >5 blocks behind the validating head for 30s |
| ArchiveNodeDown | geth metrics endpoint not scrapeable for 30s |
| ChainStalled | validating head not advancing for 2m |

To see ArchiveNodeDown fire: `docker compose stop geth`, wait ~40s, check
Prometheus > Alerts (or `curl -s localhost:9091/api/v1/alerts`), then
`docker compose start geth` and it clears.

## Production archive-node operations

The design for running archive nodes in production (client selection,
capacity, upgrades, backup, monitoring, SLOs) is in
[docs/archive-node-operations.md](docs/archive-node-operations.md). This
devnet is the local harness that validates that operational approach.

## Notes

- geth is pinned with `--state.scheme=hash`: recent geth defaults to path
  storage, which does not support archive mode.
- validator client here is prysm, using its built-in interop keys for a
  zero-config devnet. The production validator stack (teku-validator +
  web3signer + slashing db) lives in the component directories at the repo
  root.
- genesis is a one-time ceremony, not part of `make up`: regenerating it on
  restart would silently fork the chain.
