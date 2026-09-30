# Incident review: cache stampede on the catalogue after a flush

Quill & Ledger, online bookshop. Blameless review, written by Rosalind.

## Summary

An operator flushed the whole catalogue cache to remove one wrongly priced
title. Within seconds every request for a book page went to the database,
which held 1,800 concurrent connections and stopped answering. The storefront
returned errors or timed out for 27 minutes on a Thursday evening.

## Timeline (all times UTC)

- 18:40 Bashir notices a paperback listed at 0.99 instead of 9.99.
- 18:44 He runs `cache flush catalogue:*` to clear stale entries.
- 18:44 Cache hit rate drops from 97 percent to 0. Database connections climb
  from 120 to 1,800 in under 40 seconds.
- 18:46 Storefront latency alert fires. p95 is 14 seconds.
- 18:49 Rosalind takes command. Bashir explains the flush.
- 18:55 Rosalind enables the emergency page that serves a static "browse
  later" banner for search. Database load falls slightly.
- 19:02 Team restarts the catalogue service one instance at a time with a
  connection limit of 40 each. Cache begins to refill.
- 19:11 Hit rate reaches 85 percent, latency normal.
- 19:15 Incident closed.

## Impact

- 27 minutes of errors on book, search and category pages.
- About 6,900 sessions saw an error page. Checkout was unreachable for 22
  minutes, costing an estimated 640 orders.
- The database primary reached 100 percent CPU; replicas lagged by 3 minutes.

## Root cause

The catalogue cache had no request coalescing. When a key was missing, every
concurrent request for it queried the database and then wrote the result back.
A full flush made every popular key missing at once, so thousands of identical
queries ran together. The service also had no upper limit on database
connections, so it exhausted the pool instead of queuing.

## What went well

- The emergency banner page existed and reduced search load.
- The flush command was in the shell history, so the cause was known at once.
- Restarting with a connection limit was fast and effective.

## What went wrong

- A wildcard flush was available to any operator without a warning.
- Flushing at 18:44 was during the daily evening peak.
- The price error could have been fixed by deleting one key.
- Nobody knew the connection limit was unset.

## Actions

- Replace the wildcard flush with a command that requires a key prefix of at
  least three segments and prints the key count first. Owner: Bashir.
- Add request coalescing so one request per key refills the cache. Owner:
  Rosalind. Due in two sprints.
- Set a maximum of 40 connections per catalogue instance. Owner: Ewan.
- Add jitter to cache expiry so keys do not all expire together. Owner: Ewan.
- Prewarm the top 5,000 titles after any flush. Owner: Rosalind.
- Add a price sanity check that rejects a change above 80 percent. Owner: Bashir.

## Additional notes

The cache is a cluster of six Redis nodes holding roughly 2.4 million catalogue keys, with a time to live of 30 minutes for pages and 6 hours for cover metadata.
During the stampede the database logged about 41,000 identical queries for the ten most popular titles, each one taking longer as connections queued up.
Ewan's review of the connection pool showed a maximum of 200 per instance across 14 instances, far above what the database can serve in parallel.
An experiment in staging with coalescing reduced database queries after a flush from 41,000 to 380 in the first ten seconds, and latency stayed under 400 ms.
Bashir has since taken over the pricing tool review, and he points out that the wrong price came from a spreadsheet import that lacked a range check.
