# Incident review: a leap-day date bug in invoicing

Quill & Ledger, online bookshop. Blameless review, written by Lucian.

## Summary

At 00:00 UTC on 29 February the nightly `invoicer` job crashed while computing
due dates for business accounts, and then crashed again on every retry. For 19
hours no invoices were issued to 640 wholesale customers. The job computed a
due date by adding one year to the order date, which is not a valid date when
the order date is 29 February.

## Timeline (all times UTC)

- 00:00 The nightly `invoicer` job starts.
- 00:01 It reaches an account whose contract renews on 29 February and throws
  an invalid date error. The whole batch aborts.
- 00:05 Scheduler retries the job three times, each failing the same way.
- 06:30 Morning check by Amira shows the job status as failed. The alert had
  been muted for a noisy earlier problem.
- 07:10 Amira and Lucian find the stack trace in `DueDate.addYears`.
- 08:45 A fix is written that clamps to 28 February in non-leap years.
- 10:20 Fix reviewed and deployed to staging; the test replays the bad date.
- 15:40 Fix deployed to production after finance approves the invoice content.
- 19:05 The job completes. 640 invoices sent. Incident closed at 19:30.

## Impact

- 19 hours of delay for 640 invoices, worth about 218,000 in total.
- Payment terms slipped by a day for these customers; a few complained.
- No incorrect invoices were issued.

## Root cause

The date arithmetic added 12 months and then constructed a date with the
original day of the month, which fails on 29 February when the target year is
not a leap year. Our tests used fixed sample dates and none fell on a leap
day. A single failing account also aborted the whole batch instead of being
reported and skipped. The failure alert was muted after an earlier noisy
incident and never restored.

## What went well

- The stack trace pointed straight at the bug.
- Finance reviewed the fix and confirmed the invoice amounts.
- No customer received a wrong invoice.

## What went wrong

- Six hours passed before a human looked at the job.
- One bad record blocked the batch.
- The fix waited on a slow approval step, which extended the delay.

## Actions

- Process each account separately and report failures at the end. Owner:
  Lucian. Due next sprint.
- Restore the failure alert and review all muted alerts monthly. Owner: Amira.
- Add property tests over every date in four years, including 29 February.
  Owner: Lucian.
- Use the calendar library for month and year arithmetic. Owner: Lucian.
- Agree an expedited approval path for invoice fixes. Owner: Amira.

## Additional notes

The invoicer runs on a schedule at midnight UTC and produces PDF invoices that are sent by a separate mail worker in the morning of the account's time zone.
The failing function took the order date, incremented the year, and built a date from year, month and day, which throws for 29 February in a non-leap year.
Lucian searched the codebase and found two similar patterns, one in the subscription renewal reminder and one in the gift voucher expiry, both now fixed.
The replay in staging used the production database snapshot from 28 February, so the same 11 accounts with a 29 February renewal were exercised as in production.
The muted alert dated from a week when the job emailed a warning for every skipped account; it was silenced for a day and then simply forgotten by the team.
The corrected function is covered by 1,461 generated dates, and the wholesale contract terms now state that annual renewals on 29 February fall on 28 February.
