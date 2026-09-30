# Incident review: a domain's DNS record expired

Quill & Ledger, online bookshop. Blameless review, written by Ingrid.

## Summary

The domain `covers.quillandledger.example`, which serves every book cover image
on the site, stopped resolving at 06:00 UTC on a Saturday. The registration had
lapsed because the renewal notice went to a mailbox nobody read. Product pages
showed broken images for 3 hours 40 minutes.

## Timeline (all times UTC)

- 06:00 The registrar suspends the domain; its name servers stop answering.
- 06:14 Synthetic check `cover-image-load` fails from all four regions.
- 06:15 Page sent to on-call, Dmitri. He confirms images 404 at the edge with
  a resolution error.
- 06:40 Dmitri finds the registrar account is owned by a former employee's
  address. He escalates to Ingrid, the engineering manager.
- 07:10 Ingrid locates the finance contact who holds the account recovery
  details. The recovery call takes 35 minutes.
- 07:52 Registrar verifies identity and offers renewal for 10 years.
- 08:05 Renewal paid. Registrar states propagation may take hours.
- 08:30 Dmitri points product pages at the fallback host `img2` as a stopgap.
- 09:41 Resolution restored for most resolvers. Incident closed at 10:15.

## Impact

- Roughly 3 hours 40 minutes of missing cover images on every product page.
- Conversion fell 38 percent against the Saturday average, about 1,900 fewer
  orders than expected.
- Mobile apps cached failures, so some users saw blanks until Sunday morning.

## Root cause

The domain was registered under a personal account, and its renewal reminders
were addressed to a person who left the company two years ago. Auto-renew was
off because the payment card on file had expired. Nothing in our monitoring
tracked domain expiry dates, only certificate expiry.

## What went well

- Detection took 14 minutes thanks to the synthetic check.
- The `img2` fallback host existed and worked once product pages pointed at it.
- Finance and engineering cooperated quickly on a weekend.

## What went wrong

- The registrar account was unknown to most of the team.
- Recovery required documents held by one person.
- The fallback switch needed a code change, not a configuration flag.
- Mobile apps cached the failure for up to 24 hours.

## Actions

- Move all domains to the company registrar account with a shared role mailbox.
  Owner: Ingrid. Due end of month.
- Enable auto-renew with a company card and a backup card. Owner: Ingrid.
- Add a monitor that alerts 60, 30 and 7 days before each domain expires.
  Owner: Dmitri. Due next Wednesday.
- Make the image host a runtime setting so the fallback is a config change.
  Owner: Sanjay.
- Cap the mobile cache time for failed image loads at 5 minutes. Owner: Sanjay.
- Keep a list of every domain, its owner and its renewal date in the wiki.
  Owner: Ingrid.

## Additional notes

The registrar grace period was 30 days for renewal, but the suspension in this case came from a payment failure, which the registrar treats as immediate.
Ingrid later found four more domains registered to the same former employee address; two served redirects for old campaign links and two were unused.
The stopgap host `img2` served images from a stale copy that was 9 days old, so a handful of new releases showed a grey placeholder cover until propagation finished.
Sanjay measured resolver behaviour afterwards: large public resolvers recovered within 90 minutes, while some mobile carriers held the failure for nearly 5 hours.
The wiki list of domains now has 11 entries, each with an owner, a renewal date, the card used, and the person who receives the reminder emails.
