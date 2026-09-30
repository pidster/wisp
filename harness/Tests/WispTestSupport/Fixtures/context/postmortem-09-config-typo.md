# Incident review: a typo in a feature-flag config

Quill & Ledger, online bookshop. Blameless review, written by Petra.

## Summary

A one-character typo in the feature-flag configuration for the `new-basket`
experiment turned it on for 100 percent of users instead of 5 percent. The new
basket had an untested code path that mis-totalled orders containing gift
cards. For 34 minutes a share of customers saw totals that were too low by the
value of the gift card.

## Timeline (all times UTC)

- 10:02 Ahmed merges a config change to raise the experiment from 5 to 15
  percent. He writes `rollout: 150` instead of `rollout: 15`.
- 10:04 The flag service loads the file. It clamps the value at 100 without a
  warning, and every user gets the new basket.
- 10:11 Finance reports a jump in orders with total below product cost.
- 10:17 Petra checks orders and finds all affected carts contain gift cards.
- 10:24 Petra declares an incident and asks who changed the flags recently.
- 10:30 Ahmed identifies the typo and reverts the config.
- 10:36 Flag service reloads. Correct totals return for everyone.
- 10:38 Incident closed. Reconciliation continues for two days.

## Impact

- 34 minutes of mis-totalled orders for gift card carts.
- 212 orders were charged too little, a total shortfall of 3,940.
- We chose not to bill customers again; the shortfall was absorbed.
- 38 customers who saw wrong totals contacted support.

## Root cause

The flag file format accepts any integer for `rollout` and the loader silently
clamps values over 100. The config change was reviewed by one person, who read
"150" as a valid number. There was no schema check in the pipeline and no
alert on the fraction of users in an experiment. The 5 percent gate existed
only in the author's intent.

## What went well

- Finance noticed the pattern within 9 minutes.
- Reverting a config is a single merge and takes two minutes.
- The affected orders were easy to list from the gift card field.

## What went wrong

- Detection came from finance, not from engineering monitors.
- The loader hid the mistake by clamping quietly.
- Experiments could be raised by large steps with no staged approval.

## Actions

- Reject out-of-range values in the loader and fail the deploy. Owner: Ahmed.
- Add a schema and range check to the config pipeline. Owner: Petra.
- Alert when the enabled share of any flag changes by more than 10 points in
  one deploy. Owner: Petra.
- Add gift card carts to the basket integration tests. Owner: Ahmed.
- Require two reviewers for changes to rollout percentages. Owner: Petra.

## Additional notes

The flag service reloads its file every 60 seconds and had done so since the first version, so a bad value reaches all pods in about a minute after merge.
The new basket code path added the gift card credit twice as a negative line item, so the payment provider received a total lower than the true price.
Finance found the first affected order by an alert on orders below cost, a report that Petra now wants to become a real-time alert owned by engineering.
All 212 affected orders shipped normally; support wrote to the 38 customers who noticed and offered a small voucher, which about half of them used.
Ahmed wrote a short guide for the config repository describing safe experiment steps: 1, 5, 15, 50 and 100 percent, with a wait of at least one hour between steps.
A second reviewer would likely have caught the typo, since two engineers who read the diff afterwards both said the extra zero was visible once they looked for it.
The pipeline now also posts the effective rollout value to the team channel after each flag deploy, so a surprising number is seen within seconds by everyone.
