# Incident review: a schema migration held a table lock

Quill & Ledger, online bookshop. Blameless review, written by Fenella.

## Summary

A migration that added a column with a default value to the `order_lines` table
took an exclusive lock that it held for 19 minutes on a Friday afternoon. Every
query touching orders queued behind it. Checkout and the account order history
were unavailable while the lock was held, and slow for a further 12 minutes.

## Timeline (all times UTC)

- 15:00 Migration `0142_add_gift_wrap` starts in the deploy pipeline.
- 15:00 The migration issues `ALTER TABLE order_lines ADD COLUMN gift_wrap
  boolean NOT NULL DEFAULT false` and waits for an exclusive lock.
- 15:01 A long report query on `order_lines` holds a shared lock, so the alter
  waits, and every new query waits behind the alter.
- 15:03 Checkout error rate begins to climb. Connection pool reaches its cap.
- 15:07 Alert fires. Igor is on call and begins looking at the deploy.
- 15:14 Fenella, who wrote the migration, joins and recognises the pattern.
- 15:19 Igor terminates the report query. The alter proceeds and rewrites the
  table of 61 million rows, holding the exclusive lock.
- 15:22 Igor cancels the migration, but the rewrite must roll back first.
- 15:31 Rollback ends. Locks release and queued queries run.
- 15:43 Latency returns to normal. Incident closed at 15:50.

## Impact

- 19 minutes with no checkout and no order history.
- 12 further minutes of slow responses while queued work drained.
- Around 2,700 abandoned baskets. No data was lost or corrupted.

## Root cause

The migration was written for a database version where adding a column with a
default rewrote the table, and reviewers assumed a cheap change. It also
lacked a lock timeout, so it waited indefinitely and blocked all later
queries, a known behaviour of lock queues. A long reporting query on the
primary triggered the wait.

## What went well

- Fenella recognised the pattern quickly once she saw the statement.
- The rollback left the schema intact.
- Customer data was never at risk.

## What went wrong

- Reports were allowed to run on the primary during business hours.
- The migration tool ran with no lock timeout and no statement timeout.
- The deploy happened at a busy time on a Friday.

## Actions

- Set `lock_timeout` to 3 seconds in the migration tool, with retries.
  Owner: Fenella.
- Move reporting queries to a replica. Owner: Igor. Due end of month.
- Add a migration review checklist covering locks and table size. Owner:
  Fenella.
- Forbid schema deploys after 14:00 on Fridays. Owner: Igor.

## Additional notes

The table `order_lines` is 61 million rows and 38 GB, so a full rewrite took about 12 minutes on the primary once the exclusive lock was granted.
On the database version we run, adding a column with a constant default is a metadata change, but the deploy used a volatile default expression, which forces a rewrite.
Igor observed that the waiting alter blocked even simple reads, because each new query queued behind the pending exclusive lock request instead of overtaking it.
The replacement pattern is to add the column as nullable with no default, backfill in batches of 10,000 rows, and then add the constraint in a quick separate step.
Fenella reran the change against a snapshot with a 3 second lock timeout; it failed cleanly twice, then succeeded in a quiet moment in under 200 ms.
The deploy pipeline now prints the size of every table a migration touches, so a reviewer can see at once that 61 million rows deserve extra care.
