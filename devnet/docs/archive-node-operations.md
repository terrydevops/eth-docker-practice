# Ethereum Archive Nodes  -  Architecture & Operations

*Scope: operating archive nodes for compliance, analytics, and forensic workloads. Part 1 describes the local validation harness in this repo; Parts 2-4 are the production design it validates.*

---

## 1. Local validation harness (this repo)

```
                    ┌──────────────── validating node ───────────────┐
   64 interop keys  │ validator1 ──gRPC/REST── beacon1 ──engine──ge th1 │  RPC :8545
                    └───────────────────┬────────────────────────────┘
                              CL p2p (static peer)   EL p2p (bootnode)
                    ┌───────────────────┴─────── archive node ───────┐
                    │              beacon2 ──engine── geth2           │  RPC :8547
                    │   (follows the chain)     --gcmode=archive      │
                    └──────────────────────────────────────────────────┘
```

**What it proves.** A two-pair PoS devnet: one pair produces blocks continuously (64 validators, every fork through Electra active from genesis), the second pair follows the chain with **`--gcmode=archive --syncmode=full --history.transactions=0`**  -  every block executed from genesis, no state pruning, full transaction index. `make verify` asserts the archive property directly: point-in-time balance reads and `debug_traceBlockByNumber` succeed at arbitrary historical heights, which a pruned node cannot serve.

**Design decisions that carry to production:**

- **Genesis is a ceremony, not a boot step.** Genesis generation is an explicit, refuse-to-rerun script (`scripts/genesis.sh`), not a compose service. Regenerating genesis on restart silently forks a network; the failure mode was reproduced during development and designed out.
- **Deterministic identities.** EL nodekeys and the CL libp2p key are pre-generated (`scripts/gen-identities.mjs`) so peer topology is declarative and reproducible  -  no discovery races, no "works on second boot".
- **Client choice is harness-pragmatic, not a production endorsement.** geth+Prysm has the smallest reproducible devnet-genesis tooling. Production client selection is a capacity/economics decision (§2).

## 2. Production architecture

**Client selection.** For archive workloads the EL client dominates cost: hash-trie geth archive is ~20TB+ and grows fast; **Erigon/Reth's flat-storage archive is ~2-3TB** with faster historical reads and native `trace_`/`ots_` APIs that analytics teams actually use. Recommendation: **Erigon or Reth as the serving archive fleet; one geth archive replica for client diversity** (a consensus bug in one client must not take out the compliance surface). CL: any client, checkpoint-synced; the CL is fungible here  -  it only drives head updates.

**Topology.** N >= 3 archive replicas per region behind a load balancer. Reads are stateless, so horizontal scaling is trivial *except for tip consistency*: route by `X-Block-Height` affinity or expose `latest-safe` (head − 2 epochs) as the default query target so analytics jobs never observe replica-skew or short reorgs. Heavy forensic traces (`debug_traceTransaction` on pathological txs) go to a dedicated "heavy" pool with strict per-tenant concurrency limits, so one investigation can't starve compliance queries.

**Capacity.** Disk is the budget line: model growth (mainnet ~ +2-3TB/yr flat-storage archive), alert on *projected days-to-full*, not a static percentage; NVMe with >=100k random-read IOPS; memory sized to keep the recent state hot (128GB+ per serving replica). A new replica is provisioned **from snapshot, never from genesis**: genesis full-sync of a mainnet archive is a multi-week operation  -  it is the disaster-recovery floor, not the provisioning path.

## 3. Operations plan

**Deployment & upgrades.** Everything as code (Terraform for infra, Helm/compose manifests for nodes, images pinned by digest). Upgrades are stateful-system upgrades: one replica at a time, drained from the LB, upgraded, resynced to tip, soaked >=24h under mirrored read traffic before the next. Hold N-1 version across the fleet during protocol forks. **Rollback for a stateful node means restore-from-snapshot, not binary downgrade**  -  schema migrations rarely reverse; snapshots taken pre-upgrade are the rollback artifact.

**Backup & restore.** Per-replica filesystem/EBS snapshots on a fixed cadence (e.g., every 6h, retained 14d) + one "golden" snapshot validated weekly by actually restoring it and replaying to tip in a staging slot. RTO for replacing a replica = snapshot restore + catch-up sync (minutes-hours), and that number is *measured monthly*, not assumed. The unrecoverable-everything case (all snapshots bad) falls back to resync-from-a-peer or genesis  -  which is why snapshot validation is scheduled work, not best-effort.

**Monitoring.** Alerting rules and dashboards live in code. This repo already implements the pattern in miniature: Prometheus scrapes every node, Grafana serves per-client and archive-specific dashboards, and the archive alerts below are wired and verified to fire (see the repo README). The signal set that matters for archive nodes:

| Signal | Why |
|---|---|
| Block-tip lag (per replica, vs CL head) | The freshness half of the SLO; first symptom of engine/CL breakage |
| RPC error rate + latency percentiles, per method class (point-reads vs traces) | The serving half of the SLO; per-method because traces legitimately run 10-100× slower |
| Disk: usage, growth rate, **projected days-to-full** | The way archive nodes actually die |
| Peer count / engine-API health / CL sync distance | Chain-following dependencies |
| **Cross-replica correctness probe**: same historical query to all replicas, diff the answers | For forensic workloads a *wrong* answer is worse than no answer; catches silent corruption |
| Host basics: IOPS saturation, memory, restarts | Standard fleet hygiene |

**Incident response.** Runbooks per failure class (stale tip; corrupted replica; disk pressure; trace-induced overload), each with a first-move decision: *serve stale, shed load, or fail over*. A corrupted or diverging replica is removed from the LB first and diagnosed second. Blameless postmortems for every page; postmortem actions feed the automation backlog  -  the goal is that each incident class pages at most twice, ever.

**Security.** Archive RPC is never exposed raw: an authenticating gateway enforces per-tenant method allowlists (compliance tenants get `eth_*` reads; `debug_/trace_` only for the forensics tenant on the heavy pool), rate limits, and query-cost ceilings. `admin_`/`personal_` are never enabled. Engine-API JWT secrets are per-pair and rotated. Archive nodes hold **no keys**  -  they are read infrastructure; validator custody is a different security domain and stays physically separate.

## 4. SRE perspective

**SLO for archive queries.** Measured at the gateway, monthly windows: **availability 99.9%** (non-5xx, non-timeout) on the archive read surface; **latency p95 <= 300ms** for point-in-time state reads (`eth_getBalance`/`eth_call`/`eth_getStorageAt` at historical heights), **p95 <= 10s** for the trace class; **freshness: serving tip within 2 epochs of network head for 99% of minutes**. Separate SLOs per method class  -  a single blended number lets slow traces hide a broken read path.

**What breaks the error budget.** Sustained gateway 5xx/timeouts (fast-burn: >14× budget burn over 1h); tip-staleness minutes beyond the freshness SLO; and  -  counted against the budget at full weight even with zero user reports  -  **any correctness incident** (replica divergence, serving pruned-range errors after a mis-config). For compliance/forensics, wrong-but-fast is the worst failure mode we have.

**What failures are acceptable.** Loss of any single replica (LB reroutes, zero user impact  -  that's why N>=3); p99 latency spikes during compaction or snapshot I/O; CL restarts and short engine-API blips that don't move tip lag past the SLO line; planned drain/upgrade of one replica at a time. All of these consume *zero* error budget by design, and none of them page.

**What pages an on-call engineer.** (1) Serving-set unavailability or gateway fast-burn (availability SLO in danger *now*); (2) tip lag breaching freshness SLO across >=2 replicas simultaneously (common-cause: CL, engine, or upstream network issue); (3) correctness probe divergence  -  immediate page, remove replica from LB; (4) disk projected-to-full < 7 days on any serving replica; (5) golden-snapshot restore validation failure (our rollback floor is gone  -  that's an incident even though users see nothing). Everything else is a ticket, not a page: single-replica loss, slow-burn latency drift, one failed scrape.
