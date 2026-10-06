# Issue 212: Show what a sync would change before it changes anything

Opened by Ingrid Solberg (@isolberg) · labels: enhancement, cli · milestone: next minor

## The request

We use harbour to push build artefacts from our CI workers to a shared NAS. Last
month somebody ran it with `--delete` against the wrong destination, and it
removed about forty thousand files from a directory that only looked similar.
Nothing in harbour was wrong: it did exactly what it was told. What we missed was
a way to see the plan first.

I would like a mode where `harbour sync` scans and plans as usual, prints every
change it would make, and then stops without writing to the destination: no
copies, no updates, no deletions, and no manifest write either. The output
should be easy to read for a person and easy to grep in a script. Something like
one line per change, with the action first, then the path, then the size.

The exit status matters to us as much as the output. If the plan has conflicts I
want the same status a real run would give, so our wrapper can refuse to go on.

## Comments

**Maintainer (pk):** Thanks for the clear write-up. The planner already returns a
value and never writes, so most of this is printing the plan and skipping the
apply phase. Two questions: should it also verify that the destination is
writable, and should it honour `--jobs` and `--bandwidth`, which only matter
when copying?

**Ingrid Solberg:** Writable, yes, if it is cheap; a plan that cannot be applied
is not much use. The rate and worker flags can be accepted and ignored, as long
as passing them is not an error, because our wrapper always sets them.

**Contributor (rv):** One thing to watch: the manifest must not be touched, not
even its modification time. Our backup job keys off that file.

**Maintainer (pk):** Agreed on all three. Proposed output, one change per line:

    copy    docs/guide.pdf          1.2 MB
    update  bin/harbour             8.4 MB
    delete  tmp/old-report.csv           -
    conflict  notes/todo.md   edited at destination

followed by the usual summary line with the counts. In a pipe, the same lines
without alignment, tab separated.

**Contributor (rv):** Should conflicts go to standard error as they do today, or
stay with the other lines? For a preview I would keep them together, so the
whole plan reads top to bottom in one place.

**Maintainer (pk):** Together on standard output for the preview; a real run is
unchanged. I will mark this as accepted. Anyone who wants to pick it up, the
planner and the command's `run()` are the places to start, and the tests for
the planner are a good model for the new ones.

**Ingrid Solberg:** Happy to test a branch against our NAS layout when there is
one. Thank you all.
