# ADR 0080: Agent Skills, kept out of the home and checked against tampering

Date: 2026-10-24. Status: proposed. Agreed by the operator on 2026-10-24: the plans wisp runs are skills the person
configures, in the Agent Skills format, rather than recipes wisp curates or plans the model writes; skills are not
kept in the home folder but in the Mac's app or data locations; a skill is checked by its hash, so a change made
around wisp is caught; and a skill's grant is written in the format's `allowed-tools` field. The rest, marked
**pending**, is not agreed. Supplies the plans that [ADR 0079](0079-the-conversation-as-a-spine-with-task-trees.md)'s
task trees run and the grant [ADR 0078](0078-tasks-a-plan-and-its-grant.md) approves.

## Context

The planning probe of 2026-10-23 ([measurements.md](../measurements.md), "Planning a task tree and its grant") found no
local model writing a plan a person could approve: none of eighteen. An adversarial review of the design on 2026-10-24
([the proposal](../proposals/2026-10-24-task-trees.md), "Review") proposed curated recipes, fixed trees the model only
chooses and fills. The operator answered that recipes only work if the person can configure them, and that the agent
world already has the form: Agent Skills.

The format, as its specification stood on 2026-10-24 (agentskills.io/specification): a skill is a folder holding
`SKILL.md`, YAML frontmatter and then Markdown instructions, and any other files, by convention `scripts/`,
`references/`, and `assets/`.

| Field | Required | Constraint |
| --- | --- | --- |
| `name` | yes | 1 to 64 characters: lowercase letters, digits, single hyphens, not at either end; the folder's name |
| `description` | yes | 1 to 1,024 characters: what the skill does and when to use it |
| `license` | no | A licence's name or a bundled file |
| `compatibility` | no | Up to 500 characters: what the skill needs from its environment |
| `metadata` | no | A map of strings to strings, for a harness's own properties |
| `allowed-tools` | no | Space-separated tools the skill may use, pre-approved; experimental, and read differently by each harness |

Skills are disclosed progressively: every skill's name and description at start, about 100 tokens each; the body when
the skill is used (under 5,000 tokens recommended); the other files when needed. That is ADR 0079's brief, consumed
when its task starts, under a name other harnesses share, and it suits small windows: the on-device model's 8k can hold
a catalogue of names when it could not hold the skills.

A skill folder is also a supply-chain risk. Skills are written to be shared and downloaded, they carry scripts, and on
macOS any program running as the person can write wherever the person can: `~/.wisp` above all, which the
[roadmap](../roadmap.md)'s protection track describes. The operator holds that the home folder is the worst place for
executable skills.

## Decision

1. **wisp reads Agent Skills** in the format above, unchanged, so a skill written for another harness is read as
   instructions, and one written for wisp stays a valid skill elsewhere.
2. **Skills live outside the home** (agreed in direction; paths pending):

   | Skills | Where | Guarded by |
   | --- | --- | --- |
   | Shipped with wisp | Inside `Wisp.app` (`Contents/Resources/skills`) | The app's signature and App Management, which stop other apps changing a signed app in `/Applications` (ADR 0072) |
   | The person's | `~/Library/Application Support/wisp/skills/<name>/` | The hash check (decision 3) |

   Not under `~/.wisp`, and never read from a project (pending: whether a project's skills may be offered as
   instructions only, never with a grant, as a project cannot define custom tools under
   [ADR 0036](0036-custom-tools.md)). A Homebrew install has no app bundle; its shipped skills sit in the Cellar,
   which nothing guards, so they are checked as the person's are (pending).
3. **Every skill is checked by its hash before use** (agreed). When the person adds or approves a skill, wisp records
   a digest of the whole folder: every file's relative path, mode, and contents, in a fixed order, SHA-256. Each use
   recomputes it; a mismatch refuses the skill, names the files that changed, and waits for the person to approve it
   again. A digest kept where another program can write proves nothing against that program, so the record is
   anchored where it cannot: **pending**, either a keychain item limited to wisp's code signature holding the digests,
   or the protection track's keychain-held key authenticating them. Until one exists, digests in the data folder catch
   accidental and careless changes, not a determined same-user agent, and wisp says so (`wisp doctor`).
4. **A skill's grant is its `allowed-tools`** (agreed), in a wisp syntax other harnesses read as unknown tool names.
   Proposed, **pending**:

   | Entry | Grants |
   | --- | --- |
   | `read_file` `notify` `ask` | The tool, as ordinary |
   | `run_command(brew outdated --json=v2)` | This line exactly, in the sandbox |
   | `run_command(brew upgrade {formula:name})` | The line with `{formula}` filled by a value of type `name` (ADR 0079's proposal, D4), single-quoted, and never starting with `-` |
   | `run_command!(brew upgrade {formula:name})` | The same, outside the sandbox: still asked on every run ([ADR 0064](0064-an-approved-run-outside-the-sandbox.md) unchanged) |

   An entry in another harness's syntax (`Bash(git:*)`) grants nothing in wisp. Where a placeholder's value comes from,
   and what a step outputs, do not fit a space-separated list; they go in `metadata` under `wisp.` keys, strings as the
   format requires (`wisp.source.formula: "brew-outdated formulae[].name"`) (pending).
5. **The grant is approved against the digest.** Adding a skill shows its description, its grant line by line, and its
   scripts; the person approves it once. A changed digest is a new skill to approve. A grant covers only commands a
   task of that skill's tree produces from its templates, with a token only the task runner holds, never the model's
   own `run_command` with the same line (the review's finding on the gate's provenance). A dangerous verdict is never
   covered. (Pending: whether a grant may cover `high`; how long an approval lasts before the protection track.)
6. **Using a skill roots a task tree** at the turn (ADR 0079): its body becomes the active brief, its steps the tree's
   tasks; when the tree ends the body leaves the context. Only skills' names and descriptions sit in every request,
   within a share of the window (pending: the share, and how the model asks to use one: an action of the `tasks` tool,
   or a `skills` tool).
7. **A skill's scripts are commands like any other.** `scripts/` is readable inside the sandbox and never writable; a
   script runs through `run_command` (policy, classifier, sandbox, approval) unless the grant names it.
8. **The person manages skills; the model cannot install one.** `wisp skills add <folder>` (copies it in, shows it,
   records the digest), `list`, `show`, `verify`, `remove`, and `/skills` in chat (pending). The model may draft a
   `SKILL.md` for the person to read and save (pending), which is how a plan the model writes becomes one the person
   owns; it can never add, change, or approve one, and the default policy refuses `wisp skills` to it.
9. **Audited** under new kinds (pending: `skill.add`, `skill.approve`, `skill.use`, `skill.mismatch`, `skill.remove`).

## Consequences

- Plans come from the person, written once and reused; the model chooses and fills them, which the probe suggests it
  can do where it could not plan.
- wisp interoperates with a format other harnesses use, and a skill moves between them; only its grant is wisp's.
- The home stops being where executable plans are kept, ahead of the protection track's decision on the home itself
  ([ADR 0072](0072-a-dmg-and-a-declared-layout.md), decision 5).
- Tamper detection that holds against another agent needs the keychain, so skills with grants are tied to the
  protection track; skills used as instructions only are not.
- The format is young and `allowed-tools` experimental; if the specification changes the field, wisp's syntax follows
  or moves to `metadata`.
