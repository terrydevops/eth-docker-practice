# What we monitor, and why

This explains the reasoning behind each signal in the stack: what it measures,
which failure it is there to catch, and what an operator does when it fires.
Metric names are the ones this deployment actually exports; every number quoted
was read off the running stack.

The short version: **five layers, each one vouching for the layer above it.**

| Layer | Question it answers | If it is wrong, everything above it is a lie |
|---|---|---|
| 1. Chain | Is the chain alive and finalising? | Nothing else matters while the chain is stalled |
| 2. Validators | Are we earning or bleeding? | Duties are the product; penalties are silent |
| 3. Signing | Can we sign, and only once? | A signer failure looks like a validator failure |
| 4. Service | Are RPC users getting what we promised? | The only layer with an external contract |
| 5. Foundation | Is any of this being measured? | A dead collector looks exactly like a quiet system |

Diagnosis runs bottom-up (trust the foundation before believing the chain);
alerting runs top-down (page for the cause, stay quiet about symptoms).

---

## Layer 1 — Is the chain alive?

### `beacon_finalized_epoch` (teku, lighthouse)

The epoch the chain considers irreversible. **This is the first metric to look
at, not block height.**

Block production and finality fail differently, and finality fails *worse*.
A chain can keep producing blocks while finality stops - that means more than
a third of the stake is offline or disagreeing, and every block produced in
the meantime is provisional. An exchange crediting a deposit on a block that
later reorgs loses real money. Height going up is not proof the chain is
healthy; finality advancing is.

We alert when it has not advanced in 15 minutes (a ticket, not a page: brief
finality delays happen and resolve themselves), and we gate the rule on
finality existing at all, because a chain in its first epochs has none.

> **Watch out:** teku, lighthouse *and* the prysm validator client all export
> `beacon_finalized_epoch`. The validator client exports it as a constant 0
> because it has no beacon state. A query without `{job=~"teku|lighthouse"}`
> silently averages a real value with a fake zero. This is the single most
> common mistake when reading Ethereum metrics.

### `beacon_slot` minus `beacon_head_slot`

Wall-clock slot versus the slot we have actually imported: how far behind we
are, in 12-second units (6 on this devnet). Sensitive and early - a node that
is falling behind shows up here well before it stops attesting.

### `ethereum_blockchain_height` (besu) and `chain_head_block` (geth)

Execution-layer heads. Two clients, two different metric names for the same
thing - a naming inconsistency worth memorising rather than fighting.

Their **difference** is what we actually watch. Zero is healthy. A persistent
non-zero gap means either one node is lagging or, far worse, the two nodes are
on different chains - a consensus split between clients. Running two different
implementations is what makes this check possible at all: if besu and geth
agree, a bug in one of them did not silently corrupt our view of the chain.

Current: both at the same height, divergence 0.

---

## Layer 2 — Are the validators earning?

Validators do not fail loudly. They earn slightly less, then a little less
again. Nothing crashes. This layer exists because the failure mode is
*erosion*, not an outage.

### `validator_monitor_balance_gwei` (lighthouse, per validator)

Balance of each validator we track, individually. **The most honest signal in
the stack**: it nets rewards against penalties. If it falls over an hour,
penalties are exceeding rewards - the validator is missing duties, whatever
every other metric says.

Requires `--validator-monitor-auto` on the beacon node, which makes it track
the validators attached to it and report per-validator rather than in
aggregate. Aggregates hide the case where 65 validators are fine and one is
dead.

### `validator_monitor_attestation_in_block_delay_slots`

How many slots late our attestations were included. Rewards scale with
inclusion distance: an attestation included in the next slot earns full value,
one included three slots later earns materially less.

This is the classic **degradation nobody notices**. Every dashboard is green,
the validator is attesting, nothing is down - and yield is quietly 20% below
where it should be. We ticket above 2 slots sustained.

### `validator_last_attested_slot` (prysm) / `validator_duties_performed_total` (teku VC)

Proof of work performed, from the validator client's own side. The two clients
count differently, so the alerts differ: prysm exposes the last attested slot,
which we compare against the chain head; teku's validator client does not, so
we watch the rate of performed duties and alert when it goes to zero while
keys are loaded.

Mentioning this because it is a general lesson: **the same alert intent needs
different expressions per client**, and assuming one client's metric exists on
another is how coverage gaps appear.

### `beacon_current_active_validators`

Size of the active validator set, chain-wide. It moves when validators are
activated or exit. A sudden drop is a mass ejection event; a slow climb is
normal growth. On this deployment it reads 66 - 64 from genesis plus the two
we staked through the deposit contract.

---

## Layer 3 — Can we sign, and only once?

This layer only exists because we sign remotely, with keys held by web3signer
rather than the validator client. That separation buys key isolation - and it
introduces a network hop that must be watched.

### `eth2_slashingprotection_prevented_signings_total`

**The only metric in this stack that must be exactly zero, forever.**

Every other signal is a range. This one is binary. A non-zero value means
something asked the signer to sign a message that would be slashable - almost
always two validator clients loaded with the same keys. The protection did its
job, so no money was lost this time. But the misconfiguration behind it is
still there, and the next signer it meets may not have protection enabled.
Slashing costs a large part of the stake and forces an exit. It pages.

Note the asymmetry: this is good news (the guard worked) *and* an incident
(something tried). Both readings are correct, and the second is why it pages.

### `signing_bls_signing_duration`

How long a signature takes. Currently ~3.4ms against a 500ms threshold - three
orders of magnitude of headroom.

We alert far below any level that looks like an outage, because **a slow signer
misses slot deadlines long before it looks broken**. Duties have a hard
deadline: an attestation signed too late is worth less or nothing at all. A
signer at 400ms is technically "up" and quietly losing money.

### `signing_signers_loaded_count`

How many keys the signer holds. It is a sanity check with a specific job: it
makes "no duties performed" interpretable. Zero duties with zero keys loaded
is a configuration problem; zero duties with keys loaded is an outage. The
duty-stall alert is gated on this metric for exactly that reason.

---

## Layer 4 — Are we keeping our promise to users?

The archive node is a *service*. Users query historical state through it and
trust the answers. That trust is the whole product, and it is worth a moment
on why it exists at all.

Ethereum originally expected users to run light clients and verify state with
merkle proofs - trusting nobody. That protocol (LES) was removed from geth
entirely: serving it earned nothing, and after the merge a light client could
no longer judge which chain was canonical on its own. The demand did not
disappear, it moved: applications now ask a provider's archive node and
believe the answer. Which means correctness and availability are *our*
responsibility now, not the user's to verify. That is what this layer measures.

### Availability, as an error budget

We commit to 99.9% availability, measured by a synthetic prober through the
gateway rather than by the node's self-report - **user-visible truth, not
node-visible truth**. A node can be perfectly healthy while the gateway in
front of it refuses connections.

99.9% over 30 days is 43 minutes of error budget. We alert on the **rate of
consumption**, not on individual failures:

- **Fast burn** (page): spending budget 14.4x faster than sustainable, confirmed
  on both a 5-minute and a 1-hour window. At that rate a month's budget is gone
  in two days. Two windows because one window alone fires on a blip.
- **Slow burn** (ticket): 6x on 30-minute and 6-hour windows. Nothing is
  obviously broken, but the month will not be met.

Why budgets rather than thresholds: a threshold on error rate either pages for
harmless blips or misses a slow bleed. A budget answers the question the
business actually has - *will we meet the commitment* - and it turns "is this
worth waking someone for" into arithmetic rather than argument.

### Latency, split by cost class

Point reads (`eth_getBalance` and similar) and traces (`debug_traceTransaction`)
are held to different targets - 300ms and 10s p95. They are different products
sharing an endpoint. One target for both would either make point reads look
fine while they are terrible, or declare traces broken when they are normal.
The gateway routes traces to a separate, strictly capped pool for the same
reason: one expensive query must not starve the cheap ones.

### Correctness

The prober compares answers from the archive node against the validating node
and pages immediately on divergence. **A wrong answer is worse than a slow
one**, and no user will report it - they will simply act on bad data. Since the
trust model here is "believe the operator", verifying ourselves is the only
check left in the system.

### Archive tip lag

How far the archive node trails the chain head. It is the freshness half of
correctness: perfectly correct answers about a state five minutes stale are
still wrong answers to the question the user asked.

---

## Layer 5 — Is any of this real?

### `up` for every target

17 targets, all reporting. This is the foundation: if a target stops being
scraped, its metrics stop changing, and **a frozen metric looks exactly like a
healthy one** on most dashboards. Alerting on the collection itself is what
makes the other four layers trustworthy.

### `AlertmanagerDown`, and delivery counters

Before alertmanager was added, this stack had 28 alert rules and no way to
deliver any of them: they lit up a web page nobody was watching. Rules without
delivery are documentation, not monitoring.

So the delivery path is itself monitored - alertmanager's own health, its
notification failures, and counters from the receiver. **The alert that says
"alerts are not being delivered" is the most important one in the file**,
because every other alert depends on it.

### Prometheus rule-evaluation failures

A rule that fails to evaluate produces no alert - indistinguishable from a rule
that evaluated and found nothing wrong. Silent, and it disables exactly the
part of the system meant to catch problems.

### Host and container resources

Disk gets a *predictive* alert - projected time-to-full, not a static
threshold - because an archive node's disk only grows and the useful warning
is "you have days left", not "you have 5% left". Memory, CPU and OOM kills are
watched because consensus clients are memory-heavy and an OOM kill presents as
an unexplained restart.

---

## Two design rules behind the alert list

**Every alert has an owner action.** 32 rules, split between `page` (a human is
woken: chain stalled, double-sign attempted, delivery broken) and `ticket`
(handled in working hours: latency drift, slow burn, inclusion delay). An alert
nobody would act on is deleted, not silenced - unactionable alerts train people
to ignore the actionable ones.

**Causes page, symptoms stay quiet.** Alertmanager inhibition suppresses the
downstream noise: a node that is down will also stop attesting, stall its head
and fail its probes. Without inhibition one failure produces six pages at 3am
and the operator has to work out which one is the cause. With it, one page
names the cause.

---

## Two things this monitoring actually caught

Neither was hypothetical - both were found by the signals above during
development, which is the strongest argument for keeping them.

**The execution clients had zero peers.** Blocks kept flowing (the consensus
layer feeds each node directly over the engine API) so the chain looked
perfectly healthy, while the two transaction pools were isolated: a transaction
sent to one node never reached the other until it was already in a block. The
peer-count metric was the only thing that showed it, and geth's dial counter
sitting at zero is what separated "discovery never dialled" from "the handshake
failed" - without it, the obvious wrong guess is a genesis mismatch.

**Dashboards that render but are blank.** Several upstream boards queried
metrics their client had restructured away; they displayed fine and answered
nothing. Auditing every panel query against the live stack found them, and the
fix was to repoint the queries at the metrics the client exports today and
delete the panels with no equivalent. A blank panel is worse than a missing one,
because it reads as coverage.

---

## Current state

| | |
|---|---|
| Scrape targets | 17/17 up |
| Alert rules | 32 (page / ticket, routed and inhibited) |
| Active validators | 66, participation 100% |
| Finality | advancing (epoch 304) |
| EL head divergence | 0 blocks |
| Signing latency | 3.4ms (threshold 500ms) |
| Prevented signings | 0 |
| RPC availability (6h) | 100%, error budget untouched |
