# sigkill geth x1, interval 120s, 2026-09-09

| kill | head | detect s | rpc back s | recovered s | unclean shutdown | rewind |
|---|---|---|---|---|---|---|
| 1 | 13458 | 2.6 | 2.6 | 4.8 | yes | - |

predicted per kill: detect <= 6 s, recovered 15-30 s, 0.3-0.5 min budget
budget spent: -0.0 min
alerts seen: -
1h window at start: dirty (previous incident inside it, page result not counted)
steady state after: FAIL

note: the 4.8 s "recovered" is haproxy's sticky UP before fall 3 completed. The
container restart changed geth's IP (172.23.0.16 -> .11); haproxy resolves the
server name once at start and kept checking the old address (L4TOUT), so both
pools went DOWN at about 09:54:40 and stayed there until a SIGHUP reload at
09:56:36. Cost of the crash itself: about 0. Cost of the stale address: about
1.9 min of budget. The recovered column is now measured as UP with L7OK for 10 s.
