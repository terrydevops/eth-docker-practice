# sigkill geth x1, interval 120s, 2026-09-09

| kill | head | detect s | rpc back s | recovered s | unclean shutdown | rewind |
|---|---|---|---|---|---|---|
| 1 | 13505 | 1.7 | 1.7 | 13.5 | yes | - |

predicted per kill: detect <= 6 s, recovered 15-30 s, 0.3-0.5 min budget
budget spent: 0.2 min
alerts seen: RpcAvailabilityFastBurn/pending RpcAvailabilitySlowBurn/pending
1h window at start: dirty (previous incident inside it, page result not counted)
steady state after: FAIL
