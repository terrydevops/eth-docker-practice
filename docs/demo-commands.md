# Demo commands

Everything below runs from the repository root and needs the devnet up
(`cd devnet && make up`). Every fault has a stop; `make -C devnet chaos-stop`
stops all of them at once and is safe to run at any time.

Dashboards (Grafana, http://localhost:3001, folder Devnet):

- Devnet - SLOs: the promise. Row 0 is the 30-day budget.
- Devnet - SLO Validation: what a fault looks like. Recorded 10-minute
  partition: http://localhost:3001/d/devnet-slo-validation/devnet-slo-validation?from=2026-09-09T08:40:00.000Z&to=2026-09-09T09:15:00.000Z&timezone=utc
- Devnet - Serving Layer: who calls, what is refused, limits at work.
- Devnet - State Growth: storage and read cost from geth's own counters.

Red dashed lines on the charts are annotations written by the scripts at
the start and end of each fault.

## 1. Failure injection

Check before starting (all six lines must say ok):

    DRY_RUN=1 ./devnet/chaos/partition.sh

Partition, short (about 2 minutes, no budget spent, no alert; lag climbs,
the gateway halves geth1's weight, then it recovers):

    DURATION=30s RECOVER=90s ./devnet/chaos/partition.sh

Partition, the real one (16 minutes, spends about 12 minutes of budget,
pages at about T+5, ticket at about T+19; use the recorded window in the
talk unless there is time):

    DURATION=10m RECOVER=6m ./devnet/chaos/partition.sh

The kill commands below carry ALLOW_DIRTY_WINDOW=1 so they run back to
back: without it a script refuses to inject while the previous fault is
still inside the 5-minute or 1-hour SLO window (that guard exists for
the measured runs, where the page result has to be clean).

SIGKILL geth, restarted at once (about 40 seconds; detect 0.4 s, back in
rotation in about 3 s, no budget):

    ALLOW_DIRTY_WINDOW=1 ./devnet/chaos/sigkill.sh

SIGKILL geth, restarted on a new address (about 40 seconds; the gateway
follows the new address in about 14 s):

    ALLOW_DIRTY_WINDOW=1 IP_CHANGE=1 ./devnet/chaos/sigkill.sh

SIGKILL geth, nobody restarts it (down for 60 seconds, then started; shows
what a crash costs without an orchestrator):

    ALLOW_DIRTY_WINDOW=1 NO_RESTART=1 RECOVER_MAX=60 ./devnet/chaos/sigkill.sh

Stop anything, at any time (Ctrl-C in a running script does the same):

    ./devnet/chaos/stop.sh

Stopping removes the fault at once; recovery is not instant. After a
partition the archive pair has to re-peer before geth catches up. A
healed partition can leave a half-open connection on the lighthouse side
and then nothing re-dials; stop.sh waits 60 s and, if the pair is still
apart, restarts teku (the validating CL; validators miss a slot or two,
which the staking board shows). Start the next fault only when the last
line says `UP 100 L7OK`.

Note on alerts: the fast-burn page needs both the 5-minute and the 1-hour
window over the line. For one hour after a big fault a small one will also
page. To show "one crash does not page", run the kill before the
partition, not after.

Results of every run are in `devnet/chaos/results/<name>-<time>/`
(`samples.tsv`, `summary.md`).

## 2. Serving layer

Play the four callers for a minute (compliance, forensics, prober, no
key); the Serving Layer board fills within 10-20 s. Ctrl-C stops it:

    make -C devnet demo-tenants

Acceptance test, once (19 checks, about 20 s):

    make -C devnet test-rpc

The three answers by hand (keys are in devnet/.env):

    C=$(grep ^GATEWAY_KEY_COMPLIANCE= devnet/.env | cut -d= -f2)
    F=$(grep ^GATEWAY_KEY_FORENSICS= devnet/.env | cut -d= -f2)
    B='{"jsonrpc":"2.0","method":"debug_traceBlockByNumber","params":["0x1",{}],"id":1}'

    curl -s -X POST -H 'content-type: application/json' -d "$B" localhost:8548; echo                       # no key: 401
    curl -s -X POST -H 'content-type: application/json' -H "x-api-key: $C" -d "$B" localhost:8548; echo    # compliance on a trace: 403
    curl -s -X POST -H 'content-type: application/json' -H "x-api-key: $F" -d "$B" localhost:8548 | cut -c1-80; echo   # forensics: 200
    for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code} ' -X POST -H 'content-type: application/json' -H "x-api-key: $F" -d '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' localhost:8548; done; echo   # 200 x ~50 then 429

Gateway access log with the tenant per request:

    docker logs gateway --since 1m 2>&1 | grep -oE ' [0-9]{3} .*\{[a-z]*\}' | tail

## 3. State growth

The board reads geth's own counters; nothing to start. To make the
storage panels move, send transfers:

    make -C devnet traffic
