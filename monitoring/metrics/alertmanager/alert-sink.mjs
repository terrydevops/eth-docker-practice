// Minimal webhook receiver for alertmanager.
//
// A real deployment ships to Slack/PagerDuty; on a practice devnet those are
// not available, so this stands in: it logs every notification (picked up by
// promtail into loki, so alert history is queryable next to node logs) and
// exposes counters, which lets prometheus alert on its own delivery path
// going quiet.

import http from 'node:http'

const PORT = 9099
const counts = { firing: 0, resolved: 0, notifications: 0 }

const server = http.createServer((req, res) => {
  if (req.url?.startsWith('/metrics')) {
    res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' })
    res.end(
      '# HELP alert_sink_notifications_total alertmanager notifications received\n' +
      '# TYPE alert_sink_notifications_total counter\n' +
      `alert_sink_notifications_total ${counts.notifications}\n` +
      '# HELP alert_sink_alerts_total individual alerts received by status\n' +
      '# TYPE alert_sink_alerts_total counter\n' +
      `alert_sink_alerts_total{status="firing"} ${counts.firing}\n` +
      `alert_sink_alerts_total{status="resolved"} ${counts.resolved}\n`
    )
    return
  }

  if (req.method !== 'POST') {
    res.writeHead(404).end()
    return
  }

  let body = ''
  req.on('data', (c) => { body += c })
  req.on('end', () => {
    try {
      const payload = JSON.parse(body || '{}')
      counts.notifications++
      for (const a of payload.alerts ?? []) {
        if (a.status === 'resolved') counts.resolved++
        else counts.firing++
        const sev = a.labels?.severity ?? '-'
        const name = a.labels?.alertname ?? '-'
        const who = a.labels?.job ?? a.labels?.instance ?? '-'
        const summary = a.annotations?.summary ?? ''
        console.log(`[${a.status.toUpperCase()}] ${sev} ${name} (${who}) ${summary}`)
      }
    } catch (err) {
      console.error('bad payload:', err.message)
    }
    res.writeHead(200).end('ok')
  })
})

server.listen(PORT, () => console.log(`alert-sink listening on :${PORT}`))
