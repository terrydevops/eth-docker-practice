# sigkill geth x1, interval 120s, 2026-09-09

| kill | head | detect s | rpc back s | recovered s | unclean shutdown | rewind |
|---|---|---|---|---|---|---|
| 1 | 14064 | 1.4 | none | 69.2 | yes | - |

predicted per kill: detect <= 6 s, recovered 15-30 s, 0.3-0.5 min budget
budget spent: 1.0 min
alerts seen: RpcAvailabilityFastBurn/firing RpcAvailabilitySlowBurn/firing
1h window at start: dirty (previous incident inside it, page result not counted)
steady state after: FAIL
