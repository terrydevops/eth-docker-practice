# sigkill geth x1, interval 120s, 2026-09-09

| kill | head | detect s | rpc back s | recovered s | unclean shutdown | rewind |
|---|---|---|---|---|---|---|
| 1 | 14459 | 2.0 | 2.0 | 11.7 | yes | - |

predicted per kill: detect <= 6 s, recovered 15-30 s, 0.3-0.5 min budget
budget spent: 0.15 min
alerts seen: -
1h window at start: dirty (previous incident inside it, page result not counted)
steady state after: FAIL
