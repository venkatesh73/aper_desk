# Load tests

k6 scripts for the flows that actually carry traffic. They run against a
*running* server with a seeded studio — never against production without
coordinating first, because they write real rows.

    mix load.setup                 # seeds a studio and prints the credentials
    MIX_ENV=prod mix phx.server    # or a staging URL

    k6 run load/public_form.js     -e BASE=http://localhost:4000 -e STUDIO=... -e FORM=...
    k6 run load/client_gallery.js  -e BASE=http://localhost:4000 -e TOKEN=...
    k6 run load/browse.js          -e BASE=http://localhost:4000

## What each one is for

| script | shape | question it answers |
|---|---|---|
| `browse.js` | ramp to 50 VUs | can the marketing page and sign-in survive a launch? |
| `public_form.js` | constant 20 VUs | does lead capture hold up when a studio's post goes viral? |
| `client_gallery.js` | ramp to 100 VUs | what happens when a couple shares the gallery with the whole wedding? |

The last one is the realistic spike: a delivered gallery link goes into a
WhatsApp group of 150 people and they all open it within a minute. That is the
only traffic pattern this product reliably produces, and it is entirely
unauthenticated reads.

## Budgets

Thresholds are in each script and fail the run when breached, so this is a gate
rather than a report. They were set from a measured baseline on a laptop — move
them once there is a staging box worth trusting.

## What is *not* covered

LiveView's websocket traffic. k6 can drive Phoenix channels, but the payloads
are diffs meant for a browser to apply, so the scripts would break on every
markup change and tell you little. The HTTP dead render is what a cold visitor
pays for, and that is what these measure.

## Measured baseline

Taken on a laptop against a **dev-mode** server — code reloading on, no
caching, no CDN. Production will be faster, so treat these as a floor rather
than a forecast.

| script | load | p95 | failures | throughput |
|---|---|---|---|---|
| `browse.js` | 50 VUs ramp | 346 ms | 0 | 52 it/s |
| `public_form.js` | 20 VUs steady | 214 ms | 0 | 120 it/s |
| `client_gallery.js` | 100 VUs at once | 460 ms | 0 | 236 it/s |

The thresholds in each script sit comfortably above these, so a regression has
to be real before the gate trips.
