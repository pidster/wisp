# Incident review: order queue backlog after a consumer deploy

Quill & Ledger, online bookshop. Blameless review, written by Tomasz.

## Summary

On a Tuesday afternoon a deploy of the `order-intake` consumer introduced a slow
database lookup per message. The `orders.pending` queue grew from near zero to
184,000 messages over 96 minutes. Customers saw their orders accepted but no
confirmation email for up to 71 minutes. No orders were lost.

## Timeline (all times UTC)

- 13:02 Release 5.18.0 of `order-intake` starts rolling out to 12 workers.
- 13:09 Rollout completes. Queue depth is 40 messages, normal.
- 13:31 Queue depth alert fires at 5,000 messages. Priya acknowledges.
- 13:44 Priya notes consumer throughput fell from 900 to 130 messages a second.
- 14:05 Depth passes 60,000. Incident declared, Oskar becomes commander.
- 14:12 Oskar scales consumers from 12 to 30. Throughput barely moves.
- 14:26 Slow query log shows a per-message lookup on `customer_prefs`, unindexed.
- 14:31 Rollback to 5.17.4 started.
- 14:38 Rollback complete. Throughput reaches 2,400 messages a second.
- 14:38 to 16:38 Backlog drains. Incident closed at 16:41.

## Impact

- 184,000 messages delayed, peak delay 71 minutes.
- 22,300 customers received confirmation emails late.
- 412 support contacts, mostly "did my order go through".
- No data loss, no double charges.

## Root cause

Release 5.18.0 added a marketing-preference check to every order message. The
check read `customer_prefs` by `email`, a column with no index, so each lookup
scanned 3.1 million rows. Under load the database CPU saturated and every
consumer waited on it. Scaling out made the contention worse, which is why
adding consumers did not help.

## What went well

- The depth alert fired within 30 minutes of the deploy.
- Rollback took 7 minutes once it was decided.
- Messages stayed durable in the queue, so nothing needed replaying by hand.

## What went wrong

- The change was tested against a database of 5,000 rows, where the scan was
  invisible.
- Alert threshold was too high; 5,000 messages is already 40 seconds of delay
  at normal rates.
- We scaled out for 14 minutes before checking database latency.
- The status page was updated at 14:20, 75 minutes after customers were affected.

## Actions

- Add an index on `customer_prefs(email)`. Owner: Priya. Done in staging, due
  in production by Friday.
- Load test consumers against a copy of production data volumes before release.
  Owner: Oskar. Due in three weeks.
- Lower the queue depth alert to 1,000 and add an age-of-oldest-message alert.
  Owner: Tomasz. Due Thursday.
- Runbook step: check database latency before scaling consumers. Owner: Priya.
- Publish status updates within 15 minutes of declaring an incident.
  Owner: Oskar.

## Additional notes

The queue broker kept every message durable on disk, and consumers acknowledge a message only after the confirmation email has been handed to the mail provider.
Because acknowledgement was slow, unacknowledged messages piled up on each consumer, and the broker held them back from healthy peers until a timeout of 60 seconds elapsed.
After the rollback we drained the backlog with a temporary pool of 40 consumers and paused the marketing digest job so that mail provider limits were not reached.
Oskar measured the lookup at 310 ms per message on production data, against 2 ms on the staging copy, which explains why testing missed the problem entirely.
A later check showed creating the index on `customer_prefs` takes 4 minutes online and adds 90 MB, a small price for the protection it gives every consumer.
