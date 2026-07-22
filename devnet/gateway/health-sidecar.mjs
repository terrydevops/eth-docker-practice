// Freshness sidecar for the archive gateway.
//
// haproxy's own health check can tell whether geth *answers*, but not whether
// its answer is *current* - a node that has fallen behind still returns a
// valid (stale) eth_blockNumber. This sidecar closes that gap. It compares
// geth's head against besu's (the validating head) and reports lag two ways:
//
//   - an haproxy agent-check TCP server (:9999): on each connection it returns
//     a weight line, so haproxy sheds traffic *gradually* as lag grows rather
//     than all-or-nothing. In EKS this same logic becomes a readiness probe.
//   - an HTTP status endpoint (:9998/status) for humans and for a plain
//     up/down httpchk if a weighted agent is not wanted.
//
// A demo override (:9998/override) injects a synthetic lag so the shedding
// behaviour can be shown without having to actually break the chain.

import http from 'node:http'
import net from 'node:net'

// never let a stray socket error take the sidecar down - a dead freshness
// probe would make the gateway fail safe and shed all traffic
process.on('uncaughtException', (err) => console.error('uncaught:', err.message))

const BESU = process.env.BESU_RPC || 'http://besu:8545'
const GETH = process.env.GETH_RPC || 'http://geth:8545'
const SOFT_LAG = Number(process.env.SOFT_LAG || 2)   // >= this: start reducing weight
const HARD_LAG = Number(process.env.HARD_LAG || 10)  // >= this: mark down entirely
const AGENT_PORT = 9999
const HTTP_PORT = 9998

let lag = 0
let override = null   // demo: when set, used instead of the measured lag
let lastError = null

async function head(url) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}',
    signal: AbortSignal.timeout(2000),
  })
  const json = await res.json()
  return parseInt(json.result, 16)
}

async function measure() {
  try {
    const [b, g] = await Promise.all([head(BESU), head(GETH)])
    lag = Math.max(0, b - g)
    lastError = null
  } catch (err) {
    lastError = err.message
    // if we cannot measure, assume the worst so we fail safe (shed traffic)
    lag = HARD_LAG
  }
}

function effectiveLag() {
  return override === null ? lag : override
}

// haproxy agent-check: a weight (or down) as a function of freshness.
// full weight when current, half when drifting, down when too far behind.
// agent-set "down" is sticky, so the healthy responses carry an explicit
// "up" to clear it once the node has caught back up.
function weightLine() {
  const l = effectiveLag()
  if (l >= HARD_LAG) return 'down\n'
  if (l >= SOFT_LAG) return 'up 50%\n'
  return 'up 100%\n'
}

const agent = net.createServer({ allowHalfOpen: false }, (sock) => {
  // haproxy opens, reads one line, and closes; guard against it resetting the
  // connection mid-write so the process is not killed by an unhandled error
  sock.on('error', () => {})
  try { sock.end(weightLine()) } catch { /* peer already gone */ }
})
agent.on('error', (e) => console.error('agent server:', e.message))
agent.listen(AGENT_PORT, () => console.log(`agent-check on :${AGENT_PORT}`))

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  if (url.pathname === '/status') {
    const l = effectiveLag()
    const healthy = l < HARD_LAG
    res.writeHead(healthy ? 200 : 503, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ lag: l, measured: lag, override, weight: weightLine().trim(), healthy, lastError }))
    return
  }
  // demo hook: /override?lag=N to inject a synthetic lag, /override?clear to
  // clear. GET is accepted so a plain wget/curl works from the demo script.
  if (url.pathname === '/override') {
    if (url.searchParams.has('clear')) { override = null; res.end('cleared\n'); return }
    override = Number(url.searchParams.get('lag') || 0)
    res.end(`override lag=${override}\n`); return
  }
  res.writeHead(404).end()
}).listen(HTTP_PORT, () => console.log(`status on :${HTTP_PORT}`))

await measure()
setInterval(measure, 2000)
