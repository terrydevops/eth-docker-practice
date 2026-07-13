// synthetic prober for the archive rpc gateway. emits the SLIs defined in
// the README's SRE perspective section, in prometheus exposition format on
// :9600/metrics:
//   - availability + latency per method class (point reads vs traces),
//     measured through the gateway at random historical heights
//   - correctness: cross-client block-hash comparison (gateway/geth vs besu)
//     and the genesis balance invariant, which only an archive node can serve
import http from 'node:http'

const GATEWAY = process.env.GATEWAY_URL ?? 'http://gateway:8548'
const CROSS = process.env.CROSS_URL ?? 'http://besu:8545'
const ACCOUNT = process.env.PROBE_ACCOUNT ?? '0x123463a4B065722E99115D6c222f267d9cABb524'
const GENESIS_BALANCE = BigInt(process.env.PROBE_GENESIS_BALANCE ?? '0x43c33c1937564800000')
const POINT_INTERVAL_MS = 3000
const TRACE_INTERVAL_MS = 15000
const CORRECTNESS_INTERVAL_MS = 15000
const BUCKETS = [0.01, 0.025, 0.05, 0.1, 0.3, 0.5, 1, 2.5, 5, 10, 30]

// minimal metrics registry, zero dependencies
const values = new Map()
const types = new Map()
const label = (l) => Object.entries(l).map(([k, v]) => `${k}="${v}"`).join(',')
function inc(name, labels, v = 1, type = 'counter') {
  types.set(name.replace(/_(bucket|sum|count)$/, ''), type)
  const k = `${name}{${label(labels)}}`
  values.set(k, (values.get(k) ?? 0) + v)
}
function set(name, labels, v) {
  types.set(name, 'gauge')
  values.set(`${name}{${label(labels)}}`, v)
}
function observe(name, labels, seconds) {
  types.set(name, 'histogram')
  for (const b of BUCKETS) if (seconds <= b) inc(`${name}_bucket`, { ...labels, le: String(b) }, 1, 'histogram')
  inc(`${name}_bucket`, { ...labels, le: '+Inf' }, 1, 'histogram')
  inc(`${name}_sum`, labels, seconds, 'histogram')
  inc(`${name}_count`, labels, 1, 'histogram')
}
function render() {
  const seen = new Set()
  let out = ''
  for (const [k, v] of [...values.entries()].sort()) {
    const fam = k.slice(0, k.indexOf('{')).replace(/_(bucket|sum|count)$/, '')
    if (!seen.has(fam)) { seen.add(fam); out += `# TYPE ${fam} ${types.get(fam) ?? 'untyped'}\n` }
    out += `${k} ${v}\n`
  }
  return out
}

async function rpc(url, method, params, timeoutMs = 20000) {
  const t0 = performance.now()
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 }),
      signal: AbortSignal.timeout(timeoutMs),
    })
    const body = await res.json()
    const dt = (performance.now() - t0) / 1000
    if (!res.ok || body.error || body.result === undefined) return { ok: false, dt }
    return { ok: true, dt, result: body.result }
  } catch {
    return { ok: false, dt: (performance.now() - t0) / 1000 }
  }
}

async function head() {
  const r = await rpc(GATEWAY, 'eth_blockNumber', [])
  return r.ok ? parseInt(r.result, 16) : null
}
const randomHeight = (n) => '0x' + (1 + Math.floor(Math.random() * n)).toString(16)

// point-read SLI: balance of a known account at a random historical height.
// a pruned node fails this beyond its horizon; the gateway being down or the
// node answering with an error both count against availability.
async function pointProbe() {
  const n = await head()
  if (n === 0) return // chain has not started yet - nothing to measure
  const r = n ? await rpc(GATEWAY, 'eth_getBalance', [ACCOUNT, randomHeight(n)]) : { ok: false, dt: 0 }
  inc('rpc_probe_requests_total', { class: 'point', outcome: r.ok ? 'success' : 'error' })
  observe('rpc_probe_duration_seconds', { class: 'point' }, r.dt)
}

// trace SLI: block trace at a random historical height, routed by the
// gateway to the heavy pool
async function traceProbe() {
  const n = await head()
  if (n === 0) return // chain has not started yet
  const r = n
    ? await rpc(GATEWAY, 'debug_traceBlockByNumber', [randomHeight(n), { tracer: 'callTracer' }], 60000)
    : { ok: false, dt: 0 }
  inc('rpc_probe_requests_total', { class: 'trace', outcome: r.ok ? 'success' : 'error' })
  observe('rpc_probe_duration_seconds', { class: 'trace' }, r.dt)
}

// correctness: a wrong answer is worse than no answer. divergence sets the
// gauge to 0 and pages immediately (see slo-rules.yml). probe errors leave
// the gauge unchanged: unknown is not the same as diverged.
async function correctnessProbe() {
  const n = await head()
  if (n && n > 1) {
    const h = '0x' + Math.max(1, n - 16).toString(16)
    const [a, b] = await Promise.all([
      rpc(GATEWAY, 'eth_getBlockByNumber', [h, false]),
      rpc(CROSS, 'eth_getBlockByNumber', [h, false]),
    ])
    if (a.ok && b.ok) {
      const match = a.result.hash === b.result.hash
      set('rpc_correctness_ok', { check: 'cross_client_block_hash' }, match ? 1 : 0)
      inc('rpc_correctness_checks_total', { check: 'cross_client_block_hash', outcome: match ? 'match' : 'mismatch' })
    } else {
      inc('rpc_correctness_checks_total', { check: 'cross_client_block_hash', outcome: 'error' })
    }
  }
  const g = await rpc(GATEWAY, 'eth_getBalance', [ACCOUNT, '0x0'])
  if (g.ok) {
    const match = BigInt(g.result) === GENESIS_BALANCE
    set('rpc_correctness_ok', { check: 'genesis_balance' }, match ? 1 : 0)
    inc('rpc_correctness_checks_total', { check: 'genesis_balance', outcome: match ? 'match' : 'mismatch' })
  } else {
    inc('rpc_correctness_checks_total', { check: 'genesis_balance', outcome: 'error' })
  }
}

const loop = (fn, ms) => { const run = () => fn().finally(() => setTimeout(run, ms)); run() }
loop(pointProbe, POINT_INTERVAL_MS)
loop(traceProbe, TRACE_INTERVAL_MS)
loop(correctnessProbe, CORRECTNESS_INTERVAL_MS)

http.createServer((req, res) => {
  if (req.url === '/metrics') {
    res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' })
    res.end(render())
  } else {
    res.writeHead(404)
    res.end()
  }
}).listen(9600, () => console.log(`prober up: gateway=${GATEWAY} cross=${CROSS}`))
