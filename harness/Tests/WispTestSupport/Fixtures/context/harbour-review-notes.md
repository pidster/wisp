# Review notes: pull request 204, the bandwidth limit

Notes kept from the review of the change that added `--bandwidth` in 2.2.0, so
the next change to the sync command can start from what was agreed then.

## What the review asked for, and what changed

1. **One shared limit.** The first version gave each worker its own token
   bucket, so eight workers used eight times the rate. The review asked for a
   single bucket shared by all workers; the merged version has one, behind a
   lock, refilled every 50 milliseconds.

2. **Parse once, early.** The rate string was parsed inside the applier. The
   review moved parsing into option handling, so a bad value such as `10Q` is a
   usage error with exit status 1 before any scanning starts, and the applier
   receives a plain integer.

3. **Name things for what they hold.** `limit` became `bytesPerSecond`, and a
   helper called `throttle()` that also counted bytes was split in two. The
   rule the reviewers agreed on: a name says what the value is, not how it is
   used.

4. **Tests for the edges.** Zero and negative rates, a rate below one byte per
   refill interval, and a run with `--jobs 1` all got tests. The review noted
   that the planner's tests are the model to follow: build the inputs by hand,
   call one function, assert on the value it returns.

5. **No new output by default.** An early draft printed the effective rate at
   the start of every run. The review asked that nothing new appear unless
   `--verbose` is set, since scripts parse the output and the summary line is
   the only line they may rely on.

6. **Documentation in the same pull request.** The flags reference and the
   changelog were updated together with the code. Reviewers asked that every
   later change to the command do the same, and that the changelog line say
   what a user sees rather than how it was built.

## Left for later

- A per-destination rate in the configuration file. Deferred: nobody had asked
  for it, and the flag covers the case that prompted the change.
- Showing progress as a percentage. Deferred until the planner can report the
  total bytes to write before the apply phase starts; that number now exists
  as a property on the plan, so this could be picked up next.

## Process

The change took two rounds of review over three days. Most of the second round
was about naming and about the order of the checks in option handling, which
now runs from the cheapest check to the most expensive one, with filesystem
checks last.
