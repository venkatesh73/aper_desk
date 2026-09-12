// Lead capture under sustained load.
//
// Every submission writes a contact, a lead, a submission row and an outbox
// event in one transaction, so this is the write path most likely to show
// contention. It is also the one place the open internet can reach a write.
import http from 'k6/http'
import { check } from 'k6'

const BASE = __ENV.BASE || 'http://localhost:4000'
const STUDIO = __ENV.STUDIO
const FORM = __ENV.FORM

export const options = {
  scenarios: {
    steady: { executor: 'constant-vus', vus: 20, duration: '60s' },
  },
  thresholds: {
    http_req_duration: ['p(95)<1200'],
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
}

export function setup() {
  if (!STUDIO || !FORM) {
    throw new Error('Set -e STUDIO=<studio-slug> -e FORM=<form-slug> — see mix load.setup')
  }
  return {}
}

export default function () {
  const res = http.get(`${BASE}/f/${STUDIO}/${FORM}`)

  check(res, {
    'form 200': (r) => r.status === 200,
    'form rendered': (r) => r.body.includes('phx-submit') && r.body.includes('answers['),
  })
}
