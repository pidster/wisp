# ADR 0065: The documentation site, an mdBook over docs/ on GitHub Pages

Date: 2026-10-14. Status: accepted; built 2026-10-14. The audience, the generator, and the hosting chosen by the
owner on 2026-10-14; the domain, `wisp.pidster.com`, the same day.

## Context

wisp's documentation is about 133,000 words of Markdown under `docs/`: the reference pages, a page per tool,
64 decision records, proposals, and reviews, read on GitHub. GitHub renders each page well but gives no order
through them, no search across them, and no way in for someone who has not yet installed wisp: `docs/README.md`
is an index for people who already know what they are looking for, and the pages are written as contracts, not
as paths through a task.

The owner chose three things:

- **Users first, internals after.** A reader meets new task-oriented guides, then the existing reference pages,
  then the internals: design, decisions, measurements, the roadmap, engineering, the release.
- **mdBook**, a Rust tool, so the site needs no Node toolchain. The repository already builds Rust (`tools/`).
- **GitHub Pages through GitHub Actions**, built on a Linux runner on each push to `main`. The macOS CI stays
  disabled until a macOS 27 runner exists (ADR 0004); the docs need no macOS.

The site is served at **https://wisp.pidster.com**, on the owner's `pidster.com` domain, rather than at
`pidster.github.io/wisp/`.

## Decision

**The book is `docs/` itself.** `book.toml` sits at the repository root with `src = "docs"`, so `mdbook build` runs
from the root, the content folder holds only content (a `book.toml` inside it would be copied into the site), and
no page is copied or duplicated: the page GitHub shows and the page the site shows are the same file. The build
writes to `book/`, which git ignores. `docs/SUMMARY.md` is the table of contents:

| Part | Pages |
| --- | --- |
| Introduction | `introduction.md`, a landing page: what wisp is, the two faces, the safety model in five lines, where to go. `docs/README.md` stays the repository's full index |
| Guides | New, under `docs/guide/`: install and first run, delegating from Claude Code and Codex, approvals and the sandbox, local models, configuration, troubleshooting. Each is a task's path through the reference, linking to it rather than repeating it |
| Reference | `wisp.md`, `tools/` (its README and every tool), `mcp.md`, `trust.md`, `approval.md`, `logging.md`, `verification.md`, `context-management.md`, `backends.md`, `install-local-models.md`, `model-controls.md` |
| Internals | The documentation index (`README.md`), `objective.md`, `design.md`, `policy-and-sandboxing.md`, `engineering.md`, `release.md`, `measurements.md`, `roadmap.md`, `backlog.md`, `on-device-ai-todo.md`, `fm-cli.md`, the local-model research pages, every decision in number order, the proposals, and the reviews |
| Changelog | `changelog.md`, which includes the root `CHANGELOG.md` (`\{{#include ../CHANGELOG.md}}`, escaped here so this page does not include it; mdBook reads an include outside `src`) |

The proposals and reviews are in the book, under Internals. They are Markdown in `docs/`, ADRs and pages link to
them, and leaving them out would have meant rewriting those links to GitHub for no gain to a reader.

**The configuration** (`book.toml`, for mdBook 0.5.4, which refuses a key it does not know): the title `wisp` and a
description; `site-url = "/"`, since the site is a domain's root; `git-repository-url` and an
`edit-url-template` to the file on GitHub's `main` (`{path}` is the file's path in the repository);
`create-missing = false`, so a page the summary names but the tree lacks fails the build; search on;
`no-section-label`, since the decisions carry their own numbers. Two choices are not mdBook's defaults:

- **The `index` preprocessor is off** (`use-default-preprocessors = false`, with `[preprocessor.links]` named
  to keep includes). It renames every `README.md` to `index.md`, which would have put `docs/README.md` over the
  Introduction as the site's `index.html` and left every link to a `README.md` pointing at a `README.html` that
  does not exist. Off, `README.md` is `README.html` and links resolve as written.
- **`docs/assets/mermaid-init.js`** draws the seven ```` ```mermaid ```` diagrams, which GitHub draws itself and
  mdBook shows as code: it loads mermaid 11.4.1 from jsDelivr on a page that has one, and leaves the source shown
  if that fails. No preprocessor to install.

**The link rule.** Every link in a page in the book is relative and stays inside `docs/`, or is absolute. A link
that left `docs/` (to `../harness/…`, `../CHANGELOG.md`) or named a directory (`decisions/`) worked on GitHub and
would 404 on the site; each now goes to the file on GitHub (`https://github.com/pidster/wisp/blob/main/<path>`,
`tree/main/` for a directory), which works in both. On 2026-10-14 that was 7 links in four pages (three directory
links, three source files, the changelog), and the 6 links in `CHANGELOG.md`, which are read from the root, from
`changelog.md`, and in GitHub's release notes, where a relative link never resolved. Six bare placeholders in
prose (`<name>`, `<question>`), which mdBook warned of and GitHub hides as HTML, went into backticks.

**The check.** `scripts/docs-links` (POSIX `sh` and `awk`, like `scripts/check`'s other helpers; no mdBook, no
network) fails when a page under `docs/` is missing from `SUMMARY.md` (a list in the script holds deliberate
exclusions; none today), when the summary names a page twice or one that does not exist, or when a link in a page
the summary lists, or in what it includes, does not resolve on the site: outside `docs/`, a directory, a path from
the root, a missing file, or a page not in the book. It reads Markdown links and images, reference definitions,
and HTML `href`, `src`, and `srcset`, and skips code. It runs in about 0.15 s, so `scripts/check docs-links` is
part of the gate (`all`). `scripts/check docs-site` runs it and then `mdbook build`, and fails on a build that
warns; it needs mdBook and stays out of the gate. On 2026-10-14 the gate's check read 115 pages and 1,212 links,
and a separate one-off check of the built site found every relative `href` and `src` resolving, and every anchor.

**The workflow.** `.github/workflows/docs.yml` runs on a push to `main` that touches `docs/**`, `book.toml`,
`CHANGELOG.md`, `scripts/docs-links`, or the workflow, and by hand. On `ubuntu-latest` it downloads mdBook 0.5.4's
`x86_64-unknown-linux-gnu` tarball from its GitHub release and checks it against a SHA-256 written in the workflow
(`3f28de05…958cd7`, the digest GitHub's release API gives, read on 2026-10-14 and matched by downloading the file),
rather than run a third-party installer action; then `scripts/check docs-site`, `actions/upload-pages-artifact`,
and `actions/deploy-pages`. Permissions are `contents: read` for the build and `pages: write` and `id-token: write`
for the deploy alone; one concurrency group, `pages`, lets a deployment finish before the next. Actions are
pinned to their current major versions (`checkout@v7`, `upload-pages-artifact@v5`, `deploy-pages@v5`), not to
commit SHAs, as `ci.yml` pins its own.

**The domain.** GitHub serves the site at `wisp.pidster.com` once the owner, outside this change:

1. adds a DNS `CNAME` record for `wisp.pidster.com` pointing at `pidster.github.io`;
2. verifies `pidster.com` for the account in GitHub's Pages settings, which stops anyone else's repository
   claiming a subdomain of it (a takeover, should the record ever outlive the site);
3. enables Pages for the repository with GitHub Actions as its source, sets the custom domain there, and
   enforces HTTPS once the certificate is issued.

No `CNAME` file goes in the site: a Pages site deployed by a custom Actions workflow takes its domain from the
repository's settings, and ignores such a file. Nothing here calls GitHub's API or changes DNS.

## Consequences

- A new page is added to `docs/SUMMARY.md` as well as to `docs/README.md` (the release preflight checks the
  index; the gate now checks the summary). A link to anything outside `docs/` is absolute. `.claude/rules/docs.md`
  says both.
- The docs sweep before a release (`docs/release.md`, step 0) also reads the guides and the Introduction against
  the code, since they restate what the reference pages say, and builds the site.
- A broken site link is a failed commit, not a 404 found later. Anchors are not checked by the gate; the build's
  pages carry mdBook's heading ids, which match GitHub's for the headings the docs use.
- The site depends on jsDelivr for its diagrams, and on mdBook's release asset for its build; a newer mdBook means
  changing the version and the digest in the workflow and the version in `scripts/check` together.
- The guides restate facts the reference owns (defaults, commands, messages). Where they disagree, the reference
  and the code win, and the guide is fixed.
- Until the owner enables Pages, the workflow's build job still checks every push and its deploy job fails.
