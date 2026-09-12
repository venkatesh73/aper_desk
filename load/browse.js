// Marketing page and sign-in under a launch-day ramp.
//
// These are the two pages a cold visitor hits, and the only ones served to
// people who have no reason to wait. Everything else in the product is behind
// a login, where a slow page is an annoyance rather than a lost customer.
import http from 'k6/http'
import { check, group } from 'k6'

const BASE = __ENV.BASE || 'http://localhost:4000'

export const options = {
  stages: [
    { duration: '20s', target: 10 },
    { duration: '40s', target: 50 },
    { duration: '20s', target: 0 },
  ],
  thresholds: {
    // A gate, not a report. p95 rather than mean: the mean hides the
    // experience of the unlucky twentieth visitor, who is the one who leaves.
    http_req_duration: ['p(95)<800'],
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
}

export default function () {
  group('landing', () => {
    const res = http.get(`${BASE}/`)
    check(res, {
      'landing 200': (r) => r.status === 200,
      // Lower case in the markup; the page shouts it with CSS. Matching the
      // rendered look rather than the source is how a check ends up never
      // passing and nobody noticing, because a failing check is still a check.
      'landing rendered': (r) => r.body.includes('The studio system'),
    })
  })

  group('sign in page', () => {
    const res = http.get(`${BASE}/sign-in`)
    check(res, {
      'sign-in 200': (r) => r.status === 200,
      // A CSRF token means the session pipeline ran, not just that a shell
      // was returned.
      'sign-in has csrf': (r) => r.body.includes('csrf-token'),
    })
  })
}
