# Incident review: an expired internal TLS certificate

Quill & Ledger, online bookshop. Blameless review, written by Odette.

## Summary

The internal certificate that secures traffic between the `checkout` service
and the `payments-proxy` expired at 23:59 UTC on a Monday. From midnight every
payment attempt failed with a handshake error. The outage lasted 1 hour 48
minutes and blocked all card purchases.

## Timeline (all times UTC)

- 00:00 Handshakes from `checkout` to `payments-proxy` begin to fail with
  `certificate has expired`.
- 00:03 Payment success rate falls from 98 percent to 0. Alert fires.
- 00:05 On-call Hamza acknowledges and sees the expiry message in logs.
- 00:20 Hamza checks the secrets store. A renewed certificate was generated
  three weeks ago but never distributed to the proxy.
- 00:41 Hamza cannot find who runs the distribution job. He wakes Odette.
- 01:05 Odette learns the job was a manual step, done by an engineer who moved
  teams in August.
- 01:22 Certificate copied to all six proxy hosts by hand.
- 01:40 Proxies reloaded one at a time to avoid a second interruption.
- 01:48 Payment success rate returns to 98 percent. Incident closed at 02:10.

## Impact

- 1 hour 48 minutes with no card payments; wallet payments unaffected.
- About 910 checkout attempts failed, of which 300 never returned.
- Revenue loss estimated at 6,200 in the local currency, low for the hour.

## Root cause

Internal certificates were renewed automatically in the secrets store, but
delivery to the proxies was a manual runbook step that had no owner after a
team change. No monitor watched the certificate actually presented by the
proxy. The store showed a valid renewed certificate, so a dashboard reading
from it looked healthy.

## What went well

- The alert fired within three minutes, and the error was clear.
- The renewed certificate was already prepared, saving generation time.
- Rolling reloads avoided a second gap.

## What went wrong

- Delivery depended on one person's memory.
- The monitor checked the store, not what the proxy served.
- It took 36 minutes to find someone who knew the process.
- Overnight timing meant the fewest customers were affected, by luck.

## Actions

- Automate delivery with a job that renews, distributes and reloads. Owner:
  Odette. Due in four weeks.
- Probe the presented certificate on every proxy and alert at 21 and 7 days
  before expiry. Owner: Hamza. Due Friday.
- Assign an owning team to every scheduled runbook step. Owner: Odette.
- Shorten internal certificate lifetime to 30 days so rotation is routine.
  Owner: Hamza.

## Additional notes

The certificate had a lifetime of 2 years and was issued by the internal authority; the renewed one was valid for another 2 years from the date it was generated.
The six proxy hosts read the certificate from a local path, and a reload takes about 4 seconds, during which established connections continue to work as before.
Hamza's timeline shows that 22 minutes were spent looking for a distribution script that did not exist, since the process had only ever been run by hand.
The team also found two other internal certificates due to expire within 90 days, one for the search cluster and one for the warehouse gateway, and renewed both.
Odette estimated that automation removes about 45 minutes of manual work per year and, more importantly, removes the single point of knowledge behind this outage.
A test in staging expired a certificate on purpose and confirmed the new probe raised an alert 21 days ahead and again at 7 days, as intended.
