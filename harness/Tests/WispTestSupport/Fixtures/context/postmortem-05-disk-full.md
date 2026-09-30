# Incident review: a database volume filled with logs

Quill & Ledger, online bookshop. Blameless review, written by Yusuf.

## Summary

The primary PostgreSQL volume for the `reviews` service reached 100 percent at
03:12 UTC on a Sunday. The database stopped accepting writes, so customers could
read reviews but not post them, and the moderation queue stalled. Writes were
restored after 2 hours 6 minutes.

## Timeline (all times UTC)

- 01:30 A new debug setting, `log_statement = all`, is applied to the reviews
  database by a maintenance script meant for staging.
- 02:15 Disk usage passes 80 percent. A warning goes to a low priority channel.
- 03:12 Volume reaches 100 percent. The database enters read-only mode.
- 03:14 The write error alert pages Nadia.
- 03:30 Nadia finds 412 GB of statement logs in `pg_log`, 97 percent of the
  volume. She cannot delete them without disturbing the running server.
- 03:52 Nadia rotates the log files and removes all but the newest.
- 04:05 She requests a larger volume to allow safe working room.
- 04:40 Volume grown from 500 GB to 750 GB and the filesystem extended.
- 05:18 Setting reverted to `log_statement = ddl`. Writes confirmed healthy.
- 05:30 Incident closed.

## Impact

- 2 hours 6 minutes without new reviews or ratings.
- 3,300 submissions failed with an error page; about 1,100 were never resent.
- The moderation queue built a 40 minute delay afterwards.
- Read traffic was unaffected.

## Root cause

A maintenance script applied a staging-only logging setting to production
because it selected hosts by a tag that both environments shared. The setting
wrote every SQL statement to disk at roughly 150 GB per hour. The disk alert
threshold of 80 percent routed to a channel nobody watches overnight, and the
volume had no log-specific quota.

## What went well

- The write error alert paged within two minutes of the failure.
- Nadia had rights to grow the volume without a long approval chain.
- Read traffic kept working, so the site stayed browsable.

## What went wrong

- The script had no environment check.
- The 80 percent alert was not a page, and gave no rate of growth.
- Deleting logs safely took 40 minutes because the procedure was undocumented.

## Actions

- Make the maintenance script refuse hosts without an explicit environment
  argument. Owner: Yusuf.
- Page when a volume is predicted to fill within 4 hours. Owner: Nadia.
- Put logs on their own 100 GB volume. Owner: Nadia. Due next quarter.
- Write a runbook for freeing space on a database volume. Owner: Yusuf.
- Send a review failure notice to affected customers. Owner: Chiara.

## Additional notes

The reviews database serves about 1,900 writes a minute in normal operation, so the logging setting multiplied write volume and also slowed queries by around 15 percent.
Nadia chose to rotate logs rather than delete files by hand, since removing files in use by the server would not have freed space until the process restarted.
After the volume was grown, a rewrite of the busiest indexes was skipped to avoid extra load; index sizes were checked the following week and found normal.
Chiara's team sent apologies to 3,300 customers whose review was rejected, with a link to resubmit, and about 2,200 of them did so in the next two days.
The tag both environments shared was `tier=data`; the script now requires `env=production` or `env=staging`, and it prints the host list before it acts.
The follow-up capacity review projected 12 months of normal growth at 210 GB, so the new 750 GB volume leaves a comfortable margin for data alone.
