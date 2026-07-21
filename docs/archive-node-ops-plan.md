# Production Operational Plan — Ethereum Archive Node Service

An archive node is a **read-only RPC service**. It holds no keys and signs
nothing — signing belongs to the staking side of the stack. Its production
concerns are the concerns of any high-value stateful API: availability, the
front door, data that only grows, and how fast you can recover it. This plan
is organised around those, and marks what this deployment already does versus
what a production build adds.

Everything quoted was measured on the running devnet.

---

## 0. What "archive" changes about operations

A full node prunes historical state; an archive node keeps every intermediate
state trie node for every block it ever processed. Two consequences drive the
entire plan:

1. **The data only grows, and it is enormous.** Mainnet archive is tens of TB.
   Disk is not a threshold to watch, it is a capacity you continuously plan.
2. **You cannot resync it in an incident.** Building a mainnet archive node
   from genesis takes weeks. Recovery must be restore-from-snapshot, never
   resync. This single fact reshapes backup, HA and upgrade strategy.

Neither is true of a validating full node, which is why an archive service
needs its own plan rather than a generic node runbook.

---

## 1. Availability & topology

### The gap: today this is a single point of failure

The gateway routes to one backend (`server geth1`). One archive node down =
service down. Everything else in this plan is secondary to fixing that.

### Target topology

```
                 [ ELB / CDN ]         TLS · WAF · global rate limit · DDoS
                       │
                 [ gateway tier ]      method routing · per-key limit · health
                 (haproxy, ≥2)
             ┌─────────┼─────────┐
          archive-1 archive-2 archive-3    N replicas, health-checked
             │         │         │
          [ CL ]    [ CL ]    [ CL ]        each archive EL pairs with its own CL
                       │
              [ snapshot / backup store ]
```

Key properties:
- **N archive replicas** behind the gateway, so any one can be **drained** for
  maintenance or upgrade without downtime. The gateway already supports this —
  it is `server geth2 / geth3` lines plus health checks — so this is an
  infrastructure gap, not a config one.
- **Each archive EL pairs with its own CL.** An archive node still needs a
  consensus client feeding it head updates over the engine API; you do not
  share one CL across archive ELs.
- **Spread across failure domains** — different hosts, ideally different AZs,
  so a host or zone loss drops one replica, not the service.

### Already in place
- haproxy health-checks backends with a real `eth_blockNumber` call (not a TCP
  ping) and removes an unhealthy backend automatically.
- Heavy/point query pools are separated (see §3).

---

## 2. The front door (the nginx/ELB layer)

haproxy is a competent internal gateway, but the internet-facing edge of an
RPC service needs a tier in front of it. Production usually splits the door in
two:

**Outer edge — ELB / nginx / CDN:**
| Concern | Why |
|---|---|
| TLS termination | plaintext JSON-RPC cannot face the internet |
| Global rate limiting & DDoS | absorb volumetric attacks before they reach a node |
| WAF | drop malformed / abusive payloads |
| Geo distribution | latency, and a regional outage does not take the service down |

**Inner gateway — haproxy (this deployment):**
| Concern | State |
|---|---|
| Per-API-key authentication | **missing** — without it anyone can drain the node |
| Per-key rate limiting | **missing** — one client must not exhaust the pool |
| Method allowlist | **missing** — `admin_`, `personal_`, `debug_setHead` must be blocked at the edge |
| Method-class routing | **done** — trace/debug isolated from point reads |
| Backend health & failover | **done** |

The most dangerous single omission here is the **method allowlist**: an archive
node exposes `debug_`/`trace_` for legitimate reasons, but the same surface
includes state-mutating and node-control methods that must never be reachable
from outside.

---

## 3. Capacity & query management

Archive workloads are bimodal: cheap point reads (`eth_getBalance`,
`eth_getLogs`) and expensive replays (`debug_traceTransaction`,
`trace_block`). A single trace can pin a core for seconds.

### Already in place
- The gateway routes `debug_/trace_` to a **strictly capped heavy pool**
  (maxconn 2) and point reads to a wider pool (maxconn 64), with a longer
  server timeout on heavy. **One expensive query cannot starve the cheap
  ones** — the core resource-isolation problem of archive RPC.

### Production adds
- **Per-key quotas** on heavy methods specifically — trace access is a premium
  tier, not a default.
- **A caching layer** for immutable historical reads (state at a finalised
  block never changes; it is perfectly cacheable). Cuts backend load
  dramatically for the common "same historical query, many clients" pattern.
- **Read-replica scaling**: point-read pool and heavy pool can scale on
  different replica counts because their cost profiles differ.

---

## 4. Data lifecycle — the part unique to archive

### Disk growth
Archive disk grows monotonically and fast. Plan capacity as a rate, not a
level. A **predictive** disk alert — projected time-to-full — is the right
signal, not a static "5% left" threshold, because the useful warning is "you
have N days". This deployment already alerts predictively.

### Backup & recovery — the load-bearing decision
Because resync takes weeks, **recovery must be restore-from-snapshot**:
- Periodic **filesystem/volume snapshots** of a drained (or checkpoint-safe)
  archive node, shipped to object storage.
- Recovery target measured and rehearsed: bring a fresh replica from snapshot
  to serving in hours, not weeks.
- **History via era1 files** where the client supports it (geth can fetch
  pre-merge history from an HTTP endpoint), so ancient history need not be
  carried in every snapshot.
- Snapshots are tested by actually restoring them — an untested backup is a
  hope, not a plan.

### Data integrity
- **Correctness probing** (already in place): the synthetic prober compares
  the archive node's historical answers against the validating node and pages
  on divergence. Under a "trust the operator" model this self-check is the only
  thing standing between a silently corrupt state DB and a client acting on bad
  data.

---

## 5. Change management

- **Rolling client upgrades**: drain replica → upgrade → re-add → next. The
  N-replica topology in §1 is what makes zero-downtime upgrades possible.
- **Canary**: upgrade one replica, watch its SLIs against the others before
  rolling the fleet — different client versions answering the same queries is
  also a free correctness check.
- **Hard-fork readiness**: archive nodes must upgrade on schedule or they fork
  onto the wrong chain. Track fork activation, stage the upgrade ahead of it,
  verify post-fork head agreement between clients.
- **Client diversity**: this deployment runs geth for archive and besu for
  validating. Running more than one archive implementation removes the risk
  that a single client's storage bug corrupts the whole fleet's answers
  identically.

---

## 6. Observability — the strong side of this deployment

This is where the build is ahead of a typical archive service rather than
behind. It already has:

- **An availability SLO with an error budget** (99.9%), measured by a synthetic
  prober **through the gateway** — user-visible truth, not node self-report —
  with **multi-window burn-rate alerting** (fast burn pages, slow burn tickets).
- **Latency SLOs split by cost class** (point p95 ≤ 300ms, trace p95 ≤ 10s),
  because they are different products on one endpoint.
- **Correctness probing** that pages on divergence.
- **Tip-lag** monitoring: freshness is half of correctness — a perfectly
  correct answer about stale state is still the wrong answer.
- **Self-monitoring**: the collection pipeline and the alert-delivery path are
  themselves watched, so a frozen metric or an undelivered alert is caught.
- **Alert delivery** through alertmanager with severity routing and inhibition
  (cause pages, symptoms stay quiet).

Live snapshot: RPC availability 99.97% over 6h, point-read p95 ~9.5ms, archive
tip-lag 0 blocks, 17/17 scrape targets up.

### Production adds
- Multi-region synthetic probes (measure the network path real users take, not
  just localhost).
- Per-customer SLO reporting if the service is commercial.

---

## 7. Incident response & security

**Runbooks** per alert class — archive-specific ones on top of the general
runbook: disk-fill projection breached, tip-lag climbing, correctness
divergence, a replica failing health checks.

**On-call** with an escalation path; the alert routing already distinguishes
`page` (wake someone) from `ticket` (working hours).

**Security posture:**
- Node admin/engine APIs never exposed beyond the local pair (engine API is
  JWT-authenticated to its CL only).
- Method allowlist at the gateway (§2).
- TLS everywhere client-facing.
- Network isolation between the serving tier and the node internals.

---

## Gap summary

| Area | State |
|---|---|
| Query isolation (heavy vs point) | **done** |
| Backend health & auto-failover | **done** |
| SLO / error budget / burn-rate alerting | **done** |
| Correctness & freshness probing | **done** |
| Self-monitoring & alert delivery | **done** |
| Predictive disk alerting | **done** |
| **HA — multiple archive replicas** | **missing (single node today)** |
| **Edge tier — TLS, auth, per-key limit, WAF** | **missing** |
| **Method allowlist at the gateway** | **missing** |
| **Snapshot backup & rehearsed restore** | **missing** |
| **Rolling/canary upgrade process** | **missing** |
| Caching layer for immutable reads | **missing** |

The shape of the gap is worth naming: **the observability layer is ahead of a
typical production build, while the availability layer — replication, the edge
tier, and snapshot-based recovery — is behind.** The plan's priority order
follows from that: HA and recovery first, because a single node with excellent
monitoring is still a single node.
