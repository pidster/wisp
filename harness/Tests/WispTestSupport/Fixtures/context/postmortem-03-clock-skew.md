# Incident review: clock skew broke signed URLs

Quill & Ledger, online bookshop. Blameless review, written by Kwame.

## Summary

Customers who bought e-books could not download them for 52 minutes on a
Wednesday morning. Download links are signed URLs that expire after 10 minutes.
One of the three `download-gateway` hosts had a system clock running 14 minutes
fast, so it rejected every link as already expired.

## Timeline (all times UTC)

- 08:20 Host `gw-c` restarts after a kernel patch. Its time service fails to
  start, and the hardware clock has drifted 14 minutes ahead.
- 08:24 Roughly one download in three begins to fail with HTTP 403.
- 08:41 Support reports a cluster of "link expired" complaints. Lena opens a
  channel and starts investigating.
- 08:47 Lena sees the 403s come only from `gw-c`. Logs say `signature expired`.
- 08:53 Kwame compares timestamps in request logs and finds `gw-c` 14 minutes
  ahead of `gw-a` and `gw-b`.
- 09:02 `gw-c` is removed from the load balancer. Failures stop.
- 09:12 Time service on `gw-c` repaired, clock corrected, host returned.
- 09:15 Incident closed.

## Impact

- 52 minutes with about 33 percent of download attempts failing.
- 1,460 failed downloads; 391 customers retried more than twice.
- 87 support contacts. No refunds were needed.

## Root cause

The signing service creates the expiry timestamp on the issuing host, and the
gateway validates it against its own clock. A skew of more than 10 minutes
between any two hosts makes freshly issued links look expired. After the
restart, `gw-c` used an unsynchronised hardware clock because its `chronyd`
unit was disabled by the patch script. Nothing checked clock offset.

## What went well

- The 403s were isolated to one host quickly once someone compared logs.
- Removing a host from rotation is a one-command operation.
- Retries by the customer worked as soon as the bad host was gone.

## What went wrong

- We had no alert on clock offset.
- The gateway returned a generic 403 with no hint about the expiry reason.
- Detection came from support, not monitoring, 17 minutes after onset.
- The patch script disabled a unit and nobody reviewed its side effects.

## Actions

- Export `node_timex_offset_seconds` and alert above 2 seconds. Owner: Kwame.
  Due Monday.
- Validate expiry with a 60 second tolerance in both directions. Owner: Lena.
- Return a distinct error code for an expired signature. Owner: Lena.
- Fix the patch script to leave the time service enabled, and add a check that
  runs after every restart. Owner: Farid.
- Add a synthetic check that downloads a real file once a minute through each
  gateway host individually. Owner: Kwame.

## Additional notes

Signed URLs carry an expiry in seconds since the epoch and an HMAC over the path and expiry, so a host with a fast clock rejects them without ever checking the signature.
Farid found that two other hosts in the staging cluster had drifted by 3 and 6 minutes, unnoticed because staging links use a 60 minute lifetime.
The patch script ran `systemctl disable chronyd` to work around a package conflict on an old image, and the workaround was copied into the general patch path.
Lena proposed moving expiry validation to a single signing service so clocks matter in one place; this is recorded as a longer term option, not an action yet.
Customers who had retried were served correctly by the two healthy hosts, which is why the failure rate stayed near one in three instead of rising.
The clock offset alert was tested by moving one staging host 5 seconds ahead; it fired within a minute and cleared when the time service was restarted.
