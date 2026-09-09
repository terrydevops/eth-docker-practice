# Trial log

Decisions, alternatives and findings during the trial, in order. The
presentation is built from this file.

Scope chosen: direction 1 (failure injection against the SLOs) as the
spine, a slice of direction 3 (state growth and query cost) to give the
SLO thresholds a measured basis, direction 2 (RPC serving layer) designed
but deliberately not built.

## 1. Validation plan - one experiment set per Part 4 question

Part 4 of the challenge asked four questions; `docs/archive-rpc-slo.md`
answered them. Each answer is a claim, and each claim gets an experiment.

| Part 4 question | Claim to validate | How | Status |
|---|---|---|---|
| What is the SLO? | 99.9% availability, point p95 300ms, trace p95 10s, correctness - and all of it is measurable | audit the prober -> rules -> gateway chain; add a 30-day ledger so consumed budget is a number | ledger done; SLI gaps found (see 2) |
| What breaks the error budget? | errors, timeouts and wrong answers all burn budget | partition, SIGKILL, disk-full; predict the burn before each run, reconcile after | not run yet |
| What failures are acceptable? | a block or two of lag, a single probe blip, traces under 10s: no budget burn, no page | short pause below SOFT_LAG, a single failed probe; budget and alerts must not move | not run yet |
| What pages? | fast burn pages at ~T+4min, slow burn and p95 only ticket, measurement blind pages | check alert timing and severity during the runs above | not run yet; see 3b |

Experiments run against the SLI as it is, before fixing anything, so the
gaps show on the dashboard. Fix, re-run, compare.

Planned runs, in order: partition (10 min, p2p only, sidecar HTTP kept so
the stale-but-correct phase is observable), SIGKILL geth mid-import,
acceptable-failure set, disk-full (needs a bounded filesystem for the geth
datadir first - the compose volume shares the VM disk), one extra: stop
besu and watch the archive gateway go down with it (health-sidecar reads
both heads and fails safe).

## 2. What the audit found before any fault was injected

Verified against code, ranked.

1. No 30-day ledger. Burn rates existed for 5m..6h; nothing said how much
   budget was left. Fixed: `slo:rpc_error_budget_*:30d` in slo-rules.yml.
   First reading: one regenesis costs ~2 minutes of user-visible 503s,
   about 4% of the monthly budget. Burn-rate alerts saw it as a blip.
2. Wrong answers burn no budget. The correctness probe writes its own
   gauge; the availability rules only read the probe success counters.
   Divergence pages, but the ledger never moves.
3. Traces are outside the availability budget. Every availability rule
   filters `class="point"`. For a forensic workload that is the main
   product without an availability promise.
4. Stale-but-correct is invisible to the SLI, and the gateway turns
   freshness into a hard outage: the prober only asks for heights geth
   already has, so a frozen geth scores 100% until the sidecar marks it
   down at HARD_LAG (about 2 minutes); geth is the only server in both
   haproxy backends, so from then on everything is a 503.
5. Stopping besu takes the archive gateway down: the sidecar compares both
   heads and treats any error as maximum lag.
6. The latency SLI includes failed requests, so p95 improves during an
   outage.
7. Detection latency differs 20x by failure mode: crash 6s (httpchk), stall
   ~120s (freshness path).
8. Correctness reports OK during an outage because it cannot check.

## 3. Inconsistencies between the written answers and the implementation

a. Two definitions of availability. README: non-5xx, non-timeout.
   `docs/archive-rpc-slo.md`: a successful and correct answer, wrong
   answers burn budget. The code implements the README version. Decision:
   adopt the docs version (the customer is compliance and forensics; a
   wrong answer is worse than a 503) and make README, docs and rules agree.
b. "Gateway / prober down" is listed under pages in the docs; the alert
   (`SloMeasurementBlind`) is a ticket; the README does not list it.
   Decision pending: page or ticket, then align all three.

## 4. Decisions taken so far

**30-day ledger, request-weighted.** Alternative: average of the 1h
ratios (cheaper). Rejected: the probe rate is constant, both are equal,
and the counter form is the textbook definition and easier to defend.
Failed minutes are counted from failed probes; the first draft used
consumed * 43.2, which extrapolates a partial window across the month.

**CI security gate (promised to Alex).** Trivy image and secret scans,
zizmor, sha-pinned actions, digest-pinned tool images, linters. Only two
third-party actions; the rest run through pipx or a pinned container.
Findings are accepted per CVE with a reason and an expiry, never
silenced. The first run flagged a netty CVE (SNI/TLS path) in web3signer
and teku that the local scan had missed because its DB was a day older;
accepted for 30 days since both run without TLS and no upstream build has
the fix.

**Bump the stale monitoring images instead of ignoring their CVEs.**
Alternative: land the gate first with a 15-entry ignore file. Rejected:
that many "we are behind" entries make the gate untrustworthy. Every
candidate tag was scanned before switching. What remains is one CVE
(x/crypto/ssh) whose fix postdates every vendor build.

**Prometheus keeps 45 days on a named volume.** The 15d default would
have capped the 30-day ledger; the ledger was also lost on every
container recreate.

**Chaos tooling: Pumba plus shell, not a framework.** Alternatives: Chaos
Mesh (Kubernetes only), Chaos Toolkit (hypothesis DSL). Rejected: the
devnet is docker compose; a framework's value here - hypothesis first,
rollback, a journal - fits in a hundred lines of shell. Pumba is kept for
the one hard part, per-destination packet loss with automatic revert.
The same hypotheses map back to Chaos Mesh in production.

**Direction 2 designed, not built.** Method allowlisting per consumer,
per-consumer rate limits, caching of immutable historical reads. Deferred
so the time goes into proving the SLO; the gateway already routes heavy
methods to a separate pool.

## 5. Runs

**2026-09-09, partition, 30 s (functional check, doubles as the acceptable-failure run).**
First attempt cut only the outbound side (lighthouse to teku, geth to besu)
and geth kept advancing: TCP delivers the sender's unacked window whether or
not the acks come back, and a block is a few kilobytes. A partition has to be
cut on both sides. With both directions cut geth froze on the first block;
lag reached 3 at T+0:32 and the gateway halved geth1's weight (predicted
T+0:24, one sample interval off); lag peaked at 4; the cut ended at 30 s and
geth was current again at about T+1:00. Availability stayed at 1.0, budget
spent 0.0 min, no alert, geth1 never left rotation. This is the "a block or
two of lag is acceptable" claim, confirmed. Recovery after the cut is about
30 s, which feeds the 10-minute prediction. Journal:
`devnet/chaos/results/partition-20260909T074236Z`.

**2026-09-09 08:45 UTC, partition, 10 min.** Journal
`devnet/chaos/results/partition-20260909T084529Z`, table rebuilt from the
prometheus series (5 s) rather than the 15 s samples.

| event | predicted | measured |
|---|---|---|
| geth1 weight 50 | T+0:30 | T+0:35 |
| geth1 DOWN | T+2:00 | T+2:10 |
| availability 5m below 0.5 | T+2:30 | T+4:50 |
| RpcAvailabilityFastBurn firing | T+5:00 | T+5:10 |
| geth1 UP again | T+10:30 | T+13:56 |
| RpcAvailabilitySlowBurn firing | T+19:00 | T+19:25 |
| budget spent | 8.5 min | 11.7 min (27% of the month) |

Four of six within one sample interval. The two misses:

- Availability under 0.5 at T+4:50, not T+2:30: the prediction confused the
  instant with the 5-minute window, which needs 2.5 minutes of zeros to
  reach 0.5. Prediction error, corrected in the script header.
- Recovery at T+13:56, not T+10:30. The netem rules were gone at T+10:00
  and geth and besu re-peered at once, but lighthouse and teku sat at zero
  peers for about four minutes (teku's static-peer retry backs off during a
  long cut; lighthouse only uses its boot nodes at start). "Bring it back"
  is bounded by CL re-peering, not by the network. That is 3.5 minutes of
  the extra budget, and the thing to fix before this runs for a customer.

Also seen: the correctness stat stayed OK the whole time (it could not
check), p95 stayed green (fast 503s), trace failures were visible but did
not touch the budget. The slow-burn ticket fired after the outage was
already over and will stay up for about 30 minutes, as the windows say.
"Budget remaining" on the SLO board reads -450%: with 9 hours of data in a
30-day window the ratio form scales 12 minutes of failure to a whole month.
The minutes form (43.2 minus spent) is the one an operator expects;
`slo:rpc_error_budget_remaining:30d` now uses it (73% after this run).
Availability (30d) keeps the ratio form: it is the compliance view, and it
is genuinely below target until the window fills.

The run also exposed a sampling bug in the harness (the sidecar answers
503 above HARD_LAG and the empty field shifted the columns); fixed, and the
summary now comes from prometheus instead.

**2026-09-09 09:54 UTC, SIGKILL geth, once (1h window still dirty from
the partition, so the page result does not count).** Journal
`devnet/chaos/results/sigkill-20260909T095413Z`.

The crash itself was cheap: haproxy saw the refused connection in 2.6 s,
geth was back on its RPC in 1.3 s with "Unclean shutdown detected", no
rewind, head intact at 13458, no probe lost. Then the archive went down
for two minutes for a reason that had nothing to do with the crash: the
restarted container got a new IP, and haproxy resolves `geth:8545` once at
start, so its health checks kept timing out against the old address
(L4TOUT) in both pools until a SIGHUP reload re-resolved it. Second
"bring it back" failure in one day, again not the node: a restart is a
new address, and the gateway had no way to learn it. Cost about 1.9 min
of budget, versus about 0 for the crash. Fix is the resolvers section in
haproxy (re-resolve the server name from Docker DNS on every check),
which is also the auto-discovery the multi-replica plan needs. Also
seen: geth, besu, teku and lighthouse all run with restart policy `no`,
so a crashed node stays down until someone starts it; the harness had to
play orchestrator. The harness itself over-reported recovery (haproxy
shows a sticky UP until fall 3 completes); recovery is now measured as UP
with a passing L7 check for 10 s.

**2026-09-09 10:01-10:04 UTC, SIGKILL geth twice more, after adding a
`resolvers docker` section to haproxy.** Journals
`results/sigkill-20260909T100155Z` (address happened to stay the same:
detect 0.4 s, recovered 2.4 s, budget 0) and `results/sigkill-20260909T100339Z`
(address forced to change with a placeholder container, .11 to .16:
detect 1.7 s, recovered 13.5 s with no intervention, budget 0.2 min). Same
fault as the 09:54 run, where the address change cost two minutes and a
manual reload. The 13.5 s is mostly `hold valid 10s` plus `rise 2`. The
gateway now follows Docker DNS on every check, which is also the
auto-discovery a multi-replica pool needs. Not yet covered: `agent-addr
health-sidecar` is still resolved once at start (no resolvers support);
the clean answer is to run the sidecar in the gateway's network namespace.

Harness: `IP_CHANGE=1` forces the restart onto a new address; with
`ALLOW_DIRTY_WINDOW=1` only the window-free checks gate the injection.

promtail now keeps its positions file on a named volume
(`promtail-positions:/positions`); the "entry too far behind" errors after
a recreate were it re-reading every container log from the start.

**2026-09-09 10:10 and 10:15 UTC, SIGKILL geth twice more.** Journals
`results/sigkill-20260909T101051Z` and `results/sigkill-20260909T101514Z`.
The first restart landed on the same address and geth was back in 1.8 s:
haproxy never saw three failed checks, geth1 never left rotation, no probe
failed, budget 0. A crash with an instant restart on the same address is
invisible to the gateway and to the SLI; how fast the orchestrator restarts
the process matters more than anything the gateway does. The second run
forced a new address (.16 to .11): detect 0.7 s, recovered 14.1 s, budget
0.15 min, no intervention, matching the 13.5 s of the earlier forced run.
Harness: the placeholder now takes geth's old address with `--ip` (without
it Docker hands the placeholder the lowest free address and geth gets its
old one back); a kill that never leaves rotation is reported as such
instead of waiting out the recovery timeout.

**How to present the SIGKILL result.** The experiment models production:
a crashed process is restarted by an orchestrator within seconds, so the
script does that (`docker start` right after the kill) and the question is
what one crash costs under that assumption, not whether the node dies.
Two answers: the crash itself is nearly free (2 s), and the two-minute
outage in the first run came from the gateway holding a stale address,
which is fixed. Burn did move (5m window to about 30x for a few seconds)
and correctly did not page: a blip, not an incident. The devnet nodes
have no restart policy; the script stood in for it and the gap is listed.
If asked what happens without an orchestrator: DOWN in 6 s, then 503 until
someone starts it, one budget minute per minute, page after about 2.5 min.

Commands:

    ./devnet/chaos/sigkill.sh                          crash + immediate restart
    IP_CHANGE=1 ./devnet/chaos/sigkill.sh              same, restart on a new address
    NO_RESTART=1 ./devnet/chaos/sigkill.sh             crash, nobody restarts (page expected)
    KILLS=5 INTERVAL=60 ./devnet/chaos/sigkill.sh      crash loop (page expected)

The last three need a clean 1h window for the page result to count;
`ALLOW_DIRTY_WINDOW=1` runs anyway and marks the journal.

Disk-full: designed (bounded 2.5 GB loop volume, instant vs slow fill,
geth's minfreedisk self-shutdown), not run; parked for time.

## 5b. Direction 2: the serving layer

The ops plan listed per-key authentication, per-key rate limiting and a
method allowlist as missing, and called the allowlist the most dangerous
omission. Built 2026-09-09, in haproxy only, about forty lines:

- `x-api-key` maps to a tenant: prober (internal, every method, no
  limit), compliance (`eth_*` reads, 200 requests per 10 s), forensics
  (plus `debug_`/`trace_` on the heavy pool, 50 per 10 s, one heavy
  request in flight per key). Keys come from `.env` through the container
  environment; the generator writes them like the other secrets.
- Refused for everyone: `admin_`, `personal_`, `miner_`, `txpool_`,
  `debug_set*`. Bodies over 64 KiB refused. Responses are JSON-RPC error
  objects (-32001, -32601, -32005), not HTML.
- The tenant is captured into the access log, so per-tenant error and
  request rates come out of loki; the prometheus exporter does not split
  by key.
- `test-rpc.sh` gained six cases: 401 without a key, 200 and 403 for the
  compliance tier, 200 for forensics on `debug_`, 403 for `admin_`, 429
  under a burst. 16 pass, 3 skip (no transactions on the chain).

Known coarseness: the method is matched by regex on the body, so a batch
with one heavy method is heavy. Query-cost ceilings beyond size, rate and
concurrency (log ranges, EVM timeouts) belong to the node flags.

Alternatives considered:

- Kong or Tyk in front. Consumers as first-class objects, quotas backed
  by redis so limits hold across gateway replicas, a developer portal:
  that is the product layer, and the ops plan's outer edge. Not built:
  another stateful component, no native routing on the JSON-RPC method,
  and it would duplicate what haproxy already does for freshness and pool
  isolation. The shape for a customer is Kong outside, haproxy inside.
- Node-side `--http.api` lists only. Per node, not per consumer; kept as
  the second layer.
- JWT instead of keys. Nothing issues tokens here; keys in the
  environment are auditable and rotatable, and the upgrade path is clear.

Caching, designed and not built: only requests whose block parameter is
an explicit height at or below finalized minus a margin, keyed on method
plus params, unbounded TTL with a bounded LRU, placed between the gateway
and the point pool. haproxy does not cache POST, so it is a separate
component. On this devnet point reads take 9 ms, so the gain is not
measurable here; it matters for mainnet-scale traces and should be
sized with the state-growth measurements.

A third board, `Devnet - Serving Layer`, shows the product side next to
the other two, one column per caller: compliance, forensics, prober and
"no key", each with its status rates now and over time (parsed from the
gateway access log with loki), a table of the tiers on top, and the
gateway totals, keys seen and heavy-pool occupancy against its cap
(prometheus) below. `make demo-tenants` plays the four callers for a
minute so the columns light up during the talk: compliance reads and
occasionally tries a trace (403), forensics traces and bursts past its
limit (429), a keyless client keeps knocking (401).

## 6. Open questions for the team

- What availability and latency do real archive customers get promised?
- Which methods do consumers actually call; is `debug_`/`trace_` exposure
  expected?
- What is the error-budget policy when it is exhausted?
- How are upstream-unfixed CRITICALs handled today?

## 7. Gaps to raise before a real customer

- The gateway sheds a lagging archive entirely; historical reads at
  heights it already has are still correct. Height-aware routing would
  keep them.
- The freshness reference (besu) is a hard dependency of archive
  availability.
- No per-consumer authentication on the gateway.
- promtail keeps no persistent positions; cadvisor is held at 0.49 for
  the docker runtime handler.
- A disk-full test needs a bounded datadir; the compose volume shares the
  host VM disk.
- The netty CVE is unreachable only because TLS is off; in production the
  signer would sit behind its own mTLS termination and alert on any
  voluntary-exit signing request.
