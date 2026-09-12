// The one spike this product reliably produces.
//
// A couple share their gallery link in a group of 150 people and most of them
// open it within a minute. It is unauthenticated, read-heavy, image-heavy, and
// nobody involved has a reason to be patient.
import http from 'k6/http'
import { check } from 'k6'

const BASE = __ENV.BASE || 'http://localhost:4000'
const TOKEN = __ENV.TOKEN

export const options = {
  stages: [
    // A share, not a ramp: everybody arrives at once.
    { duration: '10s', target: 100 },
    { duration: '30s', target: 100 },
    { duration: '10s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<1500'],
    http_req_failed: ['rate<0.02'],
    checks: ['rate>0.98'],
  },
}

export function setup() {
  if (!TOKEN) throw new Error('Set -e TOKEN=<share token> — see mix load.setup')
  return {}
}

export default function () {
  const res = http.get(`${BASE}/g/${TOKEN}`)

  check(res, {
    'gallery 200': (r) => r.status === 200,
    'gallery rendered': (r) => r.body.includes('cg-nav'),
    // A revoked or expired link renders the refusal page, which would still
    // be a 200 — so the check has to look at what came back.
    'not the refusal page': (r) => !r.body.includes('does not open anything'),
  })
}
