#!/usr/bin/env python3
"""Run every panel query in every dashboard and report how many return data.

Upstream dashboards drift: clients rename or remove metrics and the boards
that read them are not always updated (sigp/lighthouse-metrics says so in its
own README). A dashboard that renders but is mostly blank still reads as
coverage, so this checks what actually resolves against the running stack.

  python3 monitoring/scripts/audit-dashboards.py [--verbose]

A low score is not automatically a defect. Three different causes look alike:
  - the metric was renamed or removed upstream  -> remap or drop the panel
  - the metric exists but nothing exercises it  -> expected on a devnet
    (snap sync, backfill, blob traffic, mev-boost)
  - the panel queries loki, not prometheus      -> reported separately
"""
import json
import glob
import re
import sys
import urllib.parse
import urllib.request

PROM = 'http://localhost:9091/api/v1/query'
DASHBOARDS = 'monitoring/grafana/dashboards/*/*.json'
VERBOSE = '--verbose' in sys.argv


def substitute(expr):
    """Replace grafana template variables with something promql accepts.

    Both ``$var`` and ``${var}`` spellings appear in upstream dashboards; a
    label matcher becomes a match-anything regex, everything else becomes a
    literal so the query still parses.
    """
    expr = re.sub(r'\$__rate_interval|\$__interval|\$__range', '5m', expr)
    expr = re.sub(r'\[\$\{?[a-zA-Z_]+\}?\]', '[5m]', expr)
    expr = re.sub(r'=~\s*"\$\{?[a-zA-Z_]+\}?"', '=~".*"', expr)
    expr = re.sub(r'=\s*"\$\{?[a-zA-Z_]+\}?"', '=~".*"', expr)
    return re.sub(r'\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?', '1', expr)


def query(expr):
    url = PROM + '?' + urllib.parse.urlencode({'query': expr})
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            body = json.load(response)
    except Exception:
        return 'ERR'
    if body.get('status') != 'success':
        return 'ERR'
    return 'DATA' if body['data']['result'] else 'EMPTY'


def panels_of(dashboard):
    out = []
    def walk(panels):
        for panel in panels:
            out.append(panel)
            if panel.get('panels'):
                walk(panel['panels'])
    walk(dashboard.get('panels', []))
    return out


def audit(path):
    dashboard = json.load(open(path))
    prometheus, loki = [], 0
    for panel in panels_of(dashboard):
        for target in panel.get('targets') or []:
            if not isinstance(target, dict):
                continue
            datasource = (target.get('datasource') or {})
            if isinstance(datasource, dict) and datasource.get('type') == 'loki':
                loki += 1
                continue
            if target.get('expr'):
                prometheus.append((panel.get('title', '?'), target['expr']))
    seen, hits, blanks = set(), 0, []
    for title, expr in prometheus:
        resolved = substitute(expr)
        if resolved in seen:
            continue
        seen.add(resolved)
        result = query(resolved)
        if result == 'DATA':
            hits += 1
        else:
            blanks.append((title, result, expr))
    return dashboard.get('title', path), hits, len(seen), loki, blanks


def main():
    rows = [audit(path) for path in sorted(glob.glob(DASHBOARDS))]
    rows.sort(key=lambda row: row[1] / max(row[2], 1))
    for title, hits, total, loki, blanks in rows:
        if not total:
            print(f'  n/a          {title}' + (f'  ({loki} loki queries, not checked)' if loki else ''))
            continue
        pct = 100 * hits // total
        note = f'  ({loki} loki queries, not checked)' if loki else ''
        print(f'{pct:3d}%  {hits:3d}/{total:3d}  {title}{note}')
        if VERBOSE:
            for panel_title, result, expr in blanks:
                print(f'        [{result}] {panel_title}: {expr[:80]}')


if __name__ == '__main__':
    main()
