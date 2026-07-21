# The archive-RPC SLO, in four questions

The service-level objective for the archive node's RPC surface, stated as the
four questions an on-call rotation actually asks. Every figure is measured on
the running stack by the synthetic prober (`devnet/scripts/prober.mjs`)
**through the gateway** — user-visible truth, not node self-report.

The live dashboard is `Devnet - Archive RPC SLO` in Grafana; this document is
the policy behind it.

---

## What is the SLO for archive queries?

Three promises on the archive RPC surface, plus one hard invariant:

| Target | Threshold | Currently |
|---|---|---|
| **Availability** | ≥ 99.9% — a successful, correct JSON-RPC response | 100% (6h) |
| **Point-read latency** | p95 ≤ 300ms (`eth_getBalance`, `eth_getLogs`, …) | ~9.7ms |
| **Trace latency** | p95 ≤ 10s (`debug_traceTransaction`, `trace_block`) | ~10ms |
| **Correctness** | archive answers must match the validating node | OK |

99.9% availability over 30 days is **43 minutes** of error budget. Point reads
and traces get separate latency targets because they are different products on
the same endpoint — one target for both would either flatter point reads or
condemn healthy traces.

## What breaks the error budget?

Only failures the **user** sees, at the gateway: a request that returns an
error, times out, or comes back **wrong**. The budget is spent by the *rate* of
these — tracked as a burn rate, in multiples of the sustainable spend — not by
any single event. A correctness divergence or the gateway/archive being
unreachable burns budget; internal noise that never reaches a user does not.

## What failures are acceptable?

Anything that does not cost a user a correct, timely answer:

- Brief latency spikes that stay inside the p95 targets.
- The archive node lagging the validating head by a block or two, **as long as
  answers are still correct for the height asked**.
- A single probe blip — the multi-window burn-rate design deliberately does
  not fire on one bad sample.
- Trace queries taking up to 10s — that is within their SLO, not a failure.
- Empty dashboard panels for surfaces this devnet never exercises (snap sync,
  blob traffic) — absence of load, not a fault.

## What pages an on-call engineer?

Only what is burning the budget fast or is unsafe. Slow-burn issues ticket.

| Pages (wake someone) | Why |
|---|---|
| **Availability fast burn** — >14.4× budget on both 5m and 1h windows | at that rate 30 days of budget is gone in ~2 days |
| **Correctness divergence** — archive disagrees with the validating node | a wrong answer is worse than a slow one, and no user will report it |
| **Gateway / prober down** | the SLO is unmeasured — flying blind |

| Tickets (working hours) | Why |
|---|---|
| Availability slow burn (>6× on 30m + 6h) | a week to exhaust the budget — time to act |
| Point/trace p95 over target | degraded, not down |
| Archive tip-lag climbing | freshness drifting, answers still correct |

The rule of thumb behind the split: **page only if a user is being hurt now or
the answer might be wrong; everything else is a ticket.** An alert nobody would
act on at 3am is deleted or downgraded, because unactionable pages train people
to ignore the actionable ones.

---

_Related: the engine-API SLOs (per node pair) and the staking effectiveness SLO
live in `monitoring/metrics/prometheus/slo-rules.yml`; the reasoning behind the
whole signal set is in `docs/monitoring-rationale.md`._
