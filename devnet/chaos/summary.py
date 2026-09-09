# Prediction-vs-measured table for a partition run, from the run's first
# sample time plus the haproxy and ALERTS series in prometheus (5 s
# resolution, better than the 15 s sampling in samples.tsv).
import sys, csv, json, urllib.request, urllib.parse, datetime
run = sys.argv[1]; P = "http://localhost:9091"
rows = list(csv.reader(open(f"{run}/samples.tsv"), delimiter="\t"))[1:]
t0 = datetime.datetime.strptime(rows[0][0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.UTC)
def rng(expr, start, end, step=5):
    r = json.load(urllib.request.urlopen(f"{P}/api/v1/query_range?" + urllib.parse.urlencode({"query": expr, "start": start, "end": end, "step": step})))
    return r["data"]["result"]
def fmt(sec): return "not seen" if sec is None else "T+%d:%02d" % (sec // 60, sec % 60)
def first(expr, cond, start, end):
    for s in rng(expr, start, end):
        for t, v in s["values"]:
            if cond(float(v)): return int(t - t0.timestamp())
    return None
s0 = t0.timestamp(); s1 = s0 + 60 * 60
w50   = first('haproxy_server_weight{proxy="archive_point",server="geth1"}', lambda v: v == 50, s0, s1)
down  = first('haproxy_server_status{proxy="archive_point",server="geth1",state="UP"}', lambda v: v == 0, s0, s1)
av0   = first('slo:rpc_availability:ratio_rate5m', lambda v: v < 0.5, s0, s1)
page  = first('ALERTS{alertname="RpcAvailabilityFastBurn",alertstate="firing"}', lambda v: v == 1, s0, s1)
tick  = first('ALERTS{alertname="RpcAvailabilitySlowBurn",alertstate="firing"}', lambda v: v == 1, s0, s1)
up = None
if down is not None:
    up = first('haproxy_server_status{proxy="archive_point",server="geth1",state="UP"}', lambda v: v == 1, s0 + down + 1, s1)
spent0 = float(rows[0][10]) if rows[0][10] not in ("", "-") else 0.0
spent = json.load(urllib.request.urlopen(f"{P}/api/v1/query?" + urllib.parse.urlencode({"query": "slo:rpc_error_budget_failed_minutes:30d"})))["data"]["result"][0]["value"][1]
print(f"# partition, start {rows[0][0]}\n\n| event | predicted | measured |\n|---|---|---|")
for name, pred, got in [("geth1 weight 50", "T+0:30", w50), ("geth1 DOWN", "T+2:00", down), ("availability 5m < 0.5", "T+4:40", av0),
                        ("RpcAvailabilityFastBurn firing", "T+5:00", page), ("geth1 UP again", "T+10:30", up), ("RpcAvailabilitySlowBurn firing", "T+19:00", tick)]:
    print(f"| {name} | {pred} | {fmt(got)} |")
print(f"| budget spent (min) | 8.5 | {float(spent) - spent0:.2f} |")
