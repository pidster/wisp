---
paths:
  - "docs/**"
  - "README.md"
  - "CLAUDE.md"
  - "AGENTS.md"
---

# Documentation guidance

- `docs/` is also the documentation site, an mdBook (`book.toml` at the root, ADR 0065). A new page goes in
  `docs/SUMMARY.md`, in its part (Guides, Reference, Internals; an ADR under Decisions, in number order), as well
  as in `docs/README.md`; `scripts/check docs-links`, in the gate, fails otherwise.
- Links stay inside `docs/` or are absolute. A link to anything outside `docs/` (source, `AGENTS.md`,
  `CHANGELOG.md`, `scripts/`) or to a directory is a GitHub URL, `https://github.com/pidster/wisp/blob/main/<path>`
  (`tree/main/<path>` for a directory), so it works on GitHub and on the site. A bare `<placeholder>` in prose goes
  in backticks: GitHub hides it as HTML and mdBook warns.
- `docs/README.md` is the index; add a row for every new page. Pages describe the current state and are
  edited in place. Decision records are append-only: a superseded ADR keeps its file and gains a
  "Superseded by" or "Amends" line, and the newer ADR names what it changes.
- ADR format: title, `Date: … Status: accepted.`, then `## Context`, `## Decision`, `## Consequences`.
  Number sequentially; record measurements that informed the decision, not just the conclusion.
- Which page a change touches: a tool → `docs/tools/<name>.md` and the table in `docs/tools/README.md`;
  a CLI flag, subcommand, config field, or environment variable → `docs/wisp.md`; an MCP tool or
  behaviour → `docs/mcp.md`; an audit event kind → `docs/logging.md`; a component or data flow →
  `docs/design.md`; a non-obvious or hard-to-reverse choice → a new ADR.
- Write for the reader named in the page: user pages give contracts, limits, and examples; design pages
  give mechanisms and rationale. Tables for parallel facts, prose for argument. Keep code out of prose;
  commands and JSON go in fenced blocks.
- Verified facts only. If a claim was measured or probed, say so and where (`scripts/check eval`, a probe
  on this machine on a date). Do not document intended behaviour as if it existed.
- The README is the front door: intro, quick start, doc map, developer setup. Detail belongs in `docs/`.
- Diagrams only where a reader must hold a flow, sequence, state, or structure in their head that the
  prose shows less well. Beside the prose, never instead of it, with a one-line caption before it.
  Mermaid by default (`flowchart`, `sequenceDiagram`, `stateDiagram-v2`; about 15 nodes at most; no
  styling, so it reads in GitHub's light and dark themes). Every node and arrow matches the code. A
  hand-written SVG only for a flagship picture of very high quality, in `docs/images/` with light and
  dark versions through `<picture>`, real text, `<title>`, `<desc>`, and alt text (the README overview
  is the model). Render and look at a diagram before committing it.
