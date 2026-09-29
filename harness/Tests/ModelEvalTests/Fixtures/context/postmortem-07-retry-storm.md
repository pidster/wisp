# Incident review: client retries amplified an outage

Quill & Ledger, online bookshop. Blameless review, written by Callum.

## Summary

A 90 second slowdown in the `inventory` service turned into a 41 minute outage
of the storefront because the web and mobile clients retried failed calls
immediately, up to five times each. Traffic to `inventory` rose to nearly seven
times its normal level and prevented it from recovering by itself.

## Timeline (all times UTC)

- 14:07 A routine failover of the inventory database primary begins.
- 14:08 Inventory requests slow for 90 seconds; about 8 percent fail.
- 14:09 Clients retry failed calls at once, with no delay. Request rate rises
  from 1,900 to 12,800 a second.
- 14:10 Failover finishes, but the service is saturated with retries and its
  queue is full. Error rate reaches 60 percent.
- 14:13 Alert fires. Callum takes command and Sunita joins.
- 14:20 Sunita suspects a bad failover and restarts inventory. Requests
  recover for 30 seconds, then collapse again.
- 14:31 Callum spots that request volume is six to seven times normal and is
  mostly repeats of the same calls.
- 14:38 Rate limiting at the edge set to 3,000 a second for `inventory`.
- 14:49 Error rate drops below 2 percent as retries expire.
- 14:52 Limit removed gradually. Incident closed at 15:05.

## Impact

- 41 minutes of degraded storefront; product pages lacked stock status and
  the add-to-basket button failed for 60 percent of attempts.
- 15,200 failed basket actions. Estimated lost orders: 1,100.
- The mobile app showed a raw error message to some users.

## Root cause

Clients used a retry policy of five immediate attempts with no backoff, no
jitter and no budget. A brief, ordinary slowdown therefore multiplied load at
the moment the service was weakest. The service had no load shedding, so it
tried to serve every request and served almost none well.

## What went well

- Edge rate limiting existed and worked once applied.
- The failover itself completed correctly and on time.
- Sunita kept a written log that made the review easy.

## What went wrong

- We restarted the service first, which cost 11 minutes and briefly worsened
  the queue.
- The dashboard showed error rate but not request rate by caller.
- Retry policy was set differently in each of three client libraries.

## Actions

- Adopt one shared retry policy: three tries, exponential backoff starting at
  200 ms, full jitter, and a budget of 10 percent extra load. Owner: Callum.
- Add load shedding to `inventory` that rejects excess requests quickly with a
  retry hint. Owner: Sunita. Due in six weeks.
- Add a request rate panel split by client to the storefront dashboard.
  Owner: Sunita.
- Rehearse the failover in staging under retry load. Owner: Callum.
- Add a runbook step: look at traffic volume before restarting anything.

## Additional notes

The web client used a fetch wrapper that retried on any network error or 5xx response, and the mobile client used a library default of five attempts with zero delay.
At the peak, `inventory` received 12,800 requests a second while its capacity was about 3,500, and its request queue held 9,000 entries waiting up to 25 seconds.
Sunita's restart cleared the queue, but the clients immediately sent their outstanding retries, so the queue was full again within 30 seconds of the restart.
Load shedding in similar services reduced tail latency by rejecting anything that had already waited longer than its caller would wait, a cheap rule we plan to copy.
Callum also noted that the failover took the promised 90 seconds; the problem was entirely how the clients behaved during and after that window.
