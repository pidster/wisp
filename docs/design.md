# Design

## Overview

Every face of wisp sets up through `Session.begin` and opens its conversations from the session it
returns; every tool call the model makes passes the audit wrapper, and a command also passes the policy,
the gate, and the sandbox:

```mermaid
flowchart TD
    cli["wisp respond, wisp chat"] --> begin["Session.begin"]
    tui["wisp-tui"] -->|"JSON Lines"| json["wisp chat --json"]
    json --> begin
    client["MCP client"] -->|stdio| server["WispServer"]
    server --> begin
    begin -->|"one per face, or per thread_id"| conv["WispThread: gate, tools, prompting"]
    conv --> agent["Agent"]
    agent -->|"ContextComposer, from ThreadRecord"| lms["LanguageModelSession"]
    lms -->|"tool call"| audited["AuditedTool"]
    audited --> tools["run_command, read_file, edit_file, and the rest"]
    tools -->|run_command| runner["CommandRunner"]
    tools -->|"read_file, edit_file"| gate
    runner -->|"policy passed"| gate["ApprovalGate: classifier, then Approver"]
    runner -->|"cleared"| sandbox["sandbox-exec /bin/sh -c"]
    audited -.-> audit["AuditLog"]
    gate -.-> audit
    runner -.-> audit
```

The framework owns the agent loop. When the model emits a tool call, `LanguageModelSession` decodes the
arguments into the tool's `@Generable` `Arguments` type, invokes `call(arguments:)`, appends the result to the
transcript, and continues generation. `Agent` therefore contains no loop of its own; it guards
availability, composes the transcript each request carries, and shapes the API. `read_file` and `edit_file` consult the gate without `CommandRunner`;
`current_date`, `inspect`, `notify`, and `system_info` do not consult it (see "Tools" below).

## Repository layout

| Path | Contents |
| --- | --- |
| `harness/` | Swift package: the `wisp` binary, `WispCore`, `WispMCP`, and the model backends |
| `harness/Evals/` | A second Swift package, depending on the harness by path: the model evaluations (`ModelEvalTests`), which `scripts/check eval` runs and the gate never builds |
| `tools/` | Cargo workspace: one crate per Rust tool binary |
| `docs/` | This documentation and the ADRs |
| `training/` | Labelled train, dev, and test sets for the fast classifiers; only `risk/train.tsv` is built in, as `Resources/risk-examples.tsv` |
| `scripts/check` | The quality gate for both toolchains |

## Targets

| Target | Kind | Responsibility |
| --- | --- | --- |
| `WispCore` | library | All model-facing logic, grouped by folder: `Session/` (session and session host, thread, agent and its condensing and assessment, thread record, context composer, target condensing, output references, context view and archive, the presentational-text finder, memory and recall, model selection, listing, routing, and context sizing, context policy, tool registry and catalogue), `Exec/` (command runner, policy, splitter, regex cache), `Approval/` (gate, classifiers, store, threshold), `Audit/` (events, details, log, turn clock, diagnostics, receipts and turn calls, call statistics, the event relay, the tool event trail, the log tail), `Condense/` (the condensers, the secret rules, redaction and the model sweep, the personal-data classifier and its training), `Facts/` (facts: the model, the book, subject kinds and normalisers, extraction, distillation, composition, the shared stores, the report, the running summary and its writer, and the agent's fact and summary operations), `Tools/` (the tools, the file reader, and the audit wrapper), `Config/` (config, home, transcripts), `CLI/` (the chat loop, its input, completion, events, status, and JSON Lines protocol, doctor, and the table layouts, here so they are testable), `Support/` (timeout, ids, names, paging, the notifier and its routes, the file watcher, process and memory state). |
| `WispCoreAI` | library | `CoreAIBackend`: models exported to Apple's Core AI format, through the bridge in `apple/coreai-models`. Registered by the executable at launch so `WispCore` never links it. |
| `WispMLX` | library | `MLXBackend`: models in MLX or Hugging Face layout through `mlx-swift-lm`'s bridge, compiled in only under the `MLX` package trait (Metal toolchain); otherwise registered but refusing with the reason. |
| `WispMCP` | library | `WispServer` and `ToolCatalog`: exposes wisp over MCP. Depends on `WispCore` and the official MCP Swift SDK. |
| `wisp` | executable | Argument parsing and stdin/stdout only. Subcommands `respond` (default), `chat`, `tools`, `models`, `mcp`, `logs`, `config`, `doctor`, `approvals`, `notify`, `scan`, `redact`, `watch`, `draft`, `classifier`. Session set-up is `Session.begin` in `WispCore`. |
| `EmbedSystemPrompt` | build-tool plugin | Embeds `Resources/system-prompt.md` into `WispCore` as a string constant at build time. |
| `WispTestSupport` | library, tests only | `ScriptedModel`: a `LanguageModel` that answers from a script, so the agent, tool loop, and MCP server run in tests with no model; and `ContextEval`, the context eval's scenarios and fixtures, which `ModelEvalTests` in `harness/Evals` drives on a real model. |
| `WispCoreTests`, `WispMCPTests` | tests | swift-testing suites for model-independent logic; `WispServerWireTests` drives the server through a real MCP client on an in-memory transport. |

## Components

### `ModelSelection` and `ResolvedModel`

Local runtimes are `ModelBackend`s in the `ModelBackends` registry, keyed by scheme; `ModelSelection.local`
is spelled `<backend>:<name>` and resolves through the registry. A `ResolvedModel` carries the model's
declared capabilities and their source, and `WispThread.openAgent` refuses a request that needs tool
calling the model did not declare, then records `model.resolved`; see
[ADR 0019](decisions/0019-model-backends.md). Any `LanguageModel` can be wrapped by
`ResolvedModel(selection:custom:)`. `OllamaModel` is the first backend:
its `Executor` maps the transcript onto Ollama's chat API (system, user, assistant with tool calls, tool
messages), sends tool definitions as JSON Schema and an output schema as `format`, and streams chunks back
as `response` and `toolCalls` events with usage at the end. `resolve` checks the server lists the model
(blocking briefly, because agents are created synchronously). The framework's tool loop, streaming,
transcript, and guided generation are unchanged above it. See
[ADR 0016](decisions/0016-local-runtimes-through-an-executor.md).

`ModelSelection` names the model (`system`, `private-cloud`, or `ollama:<name>`); `resolve()` checks
availability and returns a `ResolvedModel`, which erases the concrete `LanguageModel` behind session
makers and an optional token counter. See [ADR 0013](decisions/0013-model-selection.md).

### `Agent`

Keeps the conversation in a `ThreadRecord` and asks a `ContextComposer` for each request's
transcript, which a `LanguageModelSession` created by a `ResolvedModel` then runs; `resolve()` checks
availability and throws `ModelSelection.Failure.unavailable` rather than letting the first request fail
obscurely. An agent can also start from a saved `Transcript`, or from another agent's store (`/model`).

- `respond(to:)` returns a `Reply`: the text and whether the turn was condensed.
- `stream(_:onDelta:)` invokes a callback with each new fragment and returns the same `Reply`. Snapshots
  are cumulative; if a retry after mid-stream overflow starts an answer that does not continue the text
  already shown, a newline separates the two. It is a callback
  rather than an `AsyncSequence` for a concurrency reason recorded in
  [ADR 0003](decisions/0003-callback-streaming.md).
- On context overflow the `ContextPolicy` (default: condense to a token target, `TargetCondensing`; phase 2's
  fixed four turns remain as `.fixed`) rebuilds the session from a condensed transcript and retries once;
  `condensations` counts recoveries. See [context-management.md](context-management.md) and
  [ADR 0008](decisions/0008-context-condensation.md).
- `transcript` (the composed view the next request carries), `store`, `contextTokens()`, and `reset()`
  support saving, budgeting, and starting over.

### `ThreadRecord` and `ContextComposer`

The layered-context proposal separates the conversation as stored from the context each request carries
([proposal](proposals/2026-09-29-layered-context.md); phase 2 built the structure, phases 3 and 3b output
handling). One turn, as the agent runs it:

1. The prompt is audited. Every stored tool output not yet sent as a reference becomes one from this turn
   on (`ContextComposer.newReferences`): the agent marks it in the store (`referencedAt`, this turn) and
   records `context.reference`. An output no longer than its reference stays whole. When the agent keeps
   facts (`Agent.facts`), it renders the facts in force into a `FactFrame` (`ContextComposer.factFrame`).
2. The composer decides whether to condense ahead of the window, over the literal turns alone, and the
   agent applies it: saves the archive, records `context.condensation`, distils the prose of the turns it
   drops into facts with one model call in a session of its own (`FactDistiller`, audited as
   `context.distillation`), and, when the dropped turns not yet summarised come to a batch
   (`ContextComposer.summaryBatchTurns`), writes the facts and the updated running summary in that one call
   instead (`SummaryWriter`, audited as `context.distillation` and `context.summary`; `Agent.handOn`), marks the dropped entries in the store with the condensation and this turn
   (`droppedAt`), and renders the frame again. For a model that reports usage, the estimate subtracts what
   step 1 saved. Under the default policy the decision and the steps are `TargetCondensing`'s: due when the
   context, the prompt, and the next turn's headroom reach the budget; then references, distilling, and
   dropping the oldest turns, each measured, until the context is at or below its target or only the last
   turn is left (the floor), where the earlier block is squeezed and, if that is not enough, the person is told
   (`Agent.contextNote`). The agent is the loop's `CondensingHost`; the event is recorded after the steps.
3. The composer builds the request's transcript: the store's active entries, with each reply's cut
   presentational text replaced by its marker (step 6) and each tool output replaced by its reference
   (`OutputReference`: tool, entry, time, status, size, the call's arguments, first and last lines), and
   the frame's two prompt-side entries: the earlier block after the instructions, the now block before the
   request.
4. The agent publishes its store, facts, subject kinds, and turn to the conversation's `MemorySource`, when it
   has `memory` (`Agent.memory`), then puts the session over the composition, continuing the live session when it
   already holds exactly that, and starting a new one otherwise. The framework runs the tool loop, which carries this turn's own
   outputs whole; an overflow condenses the active view as it was before the prompt and retries once.
5. The entries the session added, whether the turn succeeded or failed, go into the store, each with
   references (`AuditReference`: session, turn, and the event's `id`) to the audit events that recorded
   it, and its time. Tool events come from the conversation's `ToolEventTrail`, an `AuditSink` every
   `WispThread` tees its log into. The frame's entries are not stored. From the same tool events the
   agent extracts facts without a model (`FactExtraction`) and records them, then renders the frame again.
6. After a turn that succeeded, the composer looks in each of its replies for presentational text:
   a stretch that reproduces one of the turn's tool outputs exactly, formatting aside (`Presentation`).
   The agent marks each stretch on the reply's store entry as a `Cut` (segment, byte range, the output's
   store id) and records `context.cut`. The reply returned to the caller and the entry's value stay
   whole; from the next request on, the composer sends the marker instead. Because a rewritten reply or
   output keeps its id, the agent compares replies and outputs by content as well as ids when deciding
   whether the live session still holds the composition.

The store is a value type the agent owns, in memory only: it caches each entry's framework value so
composing never reads the audit files, and the audit log remains the only verbatim record on disk
(decision D8). The composer is pure; it holds the `ContextPolicy`, the budget, and whether it cuts
presentational text (`cutsPresentation`) and sends outputs as references (`referencesOutput`), both on by
default; `ContextEquivalenceTests` runs with both off to prove phase 2's structure unchanged. Cuts,
times, and the turns entries were dropped or referenced from are saved with the store's links
(`transcripts/<name>.store`), so a resumed conversation composes them again; the saved transcript holds
the replies and outputs whole. Because the store knows the turn of each change,
`ContextComposer.composition(_:atTurn:)` rebuilds the context of any earlier turn; `ContextView` renders
a composition, or the list of turns, as Markdown for chat's `/inspect context next|N|turns`, `wisp-tui`, and the MCP context
resources, and `Paging` bounds it. The order is fixed by the framework and the composer: the instructions
entry (wisp's prompt, the operator's extension, the caller's instructions, and the tool definitions) first
and unchanged for the conversation, then the earlier block (permanent facts, dynamic facts, then the
running summary of phase 4b), the turns oldest first, the now block (ephemeral facts, the task), then the
request: D12's order by stability. The composer's `summarises` switch (on by default) is off in
`ContextEquivalenceTests` with the others; its versions (`RunningSummary`) are kept in the store and saved
with its links.

**Memory** (phase 4c; [tools/memory.md](tools/memory.md)) reads the store, and adds to the facts, from outside
the agent: the framework calls `MemoryTool` on its own task, so the agent publishes a copy of its store, every
fact it sees, the subject kinds, and the turn into a `MemorySource` (a `final class` with a `Mutex`, one per
`WispThread`) before every request, and takes the notes the tool left there when the turn ends, recording them
as the model's facts (method `noted`) in `remember`, beside the turn's extracted facts. `Memory` is pure: it
reads the verb (`recall`, `note`, `task`; none is a recall) and a note's or a task's form and rules. `Recall` is pure too: it reads
what follows `recall` (`entry 7`, `turn 3`, `task`, `summary`, `fact …`, with `from line N`), gathers the
material, and pages it at 4 KiB. An entry's content is read from the audit event its store entry refers to,
through `AuditLog.event(_:)`, which asks the log's sink when it is an `AuditReader` (`FileAuditSink` searches
its files for the id, newest first; `MemoryAuditSink` and `TeeAuditSink` too); the store's copy is the fallback
(D8). `memory` is a built-in tool, so a thread given every tool has it and a named list only when it names it;
`WispThread.openAgent` wires it and renders the prompt with its rule
(`Prompting.rendered(toolsAvailable:memory:)`); the composer's `recalls` switch makes references name it. Each
call records `context.memory`.

**The assessment** (phase 4d; [context-management.md](context-management.md), "The assessment per request") is
off unless `Agent.assessment` holds `AssessmentSettings` (which `WispThread.openAgent` sets from `assessment.enabled`,
with `infersTask` only for chat). Between step 1 and step 2 the agent assesses the request (`Agent.assess`):
`AssessmentRules`, pure, decide the tools and whether the request is settled; otherwise `Assessor`'s one call, in a
session of its own with a `@Generable` answer, adds tools (only allowed ones), a task (recorded as the model's, method
`inferred`, never over the person's or a caller's), and fact ids; a failure falls back to every tool. The agent sets
`ContextComposer.registered` (the request's tools) and keeps what the next request's rules need in an
`AssessmentState` (the previous turn's tools, the task's, and the grown set). The composer adds the catalogue
(`ContextComposer.catalogue`, `ToolCatalogue`) to the instructions entry as a segment with a stable id and limits the
entry's definitions to the registered tools (`instructed`), and the agent builds each session with only those tools
(`registeredTools`), starting a new session when the set changes. The now block gains the relevant facts and the tools
line (`requestNotes`, `FactFrame.addingNow`). `withToolRecovery`, outside the overflow recovery, retries a request
once with every tool when the framework refuses a call to an unregistered tool. Each assessment and retry records
`context.assessment`; the store keeps each turn's tool set (`ThreadRecord.toolSets`, in memory) so an earlier turn's
context shows the definitions it carried.

**Facts** (phase 4a; [context-management.md](context-management.md), "Facts") are `Fact` values in a
`FactBook` per scope: the conversation's in `ThreadRecord.facts`, a value saved with the store's
links; the session's ephemeral facts and the shared permanent ones in `SharedFacts`, a `final class` with
a `Mutex` since every operation is one short critical section, the permanent one written to
`~/.wisp/facts.json` on each change. `Session` owns both shared books, and `WispThread.setUp` hands them,
with the config's `SubjectKinds`, to each agent as `FactSettings`, so an MCP server's threads share the
session's facts. `FactView` merges the current facts of the three books by `{subject, name}` and orders
each group's heads by precedence; `FactComposition` renders the frame within `factsShare` of the window;
`FactReport` renders them for the person (`/inspect facts`, `/task`, the MCP facts resources). The
person's changes go through `Agent.stateFact`, `deleteFact`, `setFactScope`, and `setTask`, each audited.

Proposed permanent facts are also mirrored, whenever a conversation's facts change
(`Agent.syncProposals`, from `refreshFacts`), into `FactProposals`, one per `Session` and shared through
`FactSettings`: a `final class` with a `Mutex` holding a copy of each proposal with its conversation and its
status (awaiting, moved, withdrawn). A face lists from it (`/inspect facts`, `wisp://facts/proposed`), so a
proposal can be listed from another conversation or after its own has gone; the owning conversation marks its
copy superseded at its next sync after another conversation moved it.

A fact's scope is a state the person sets by command, not a host effect (ADR 0044, amended 2026-09-30, which
withdrew the fact-approval dialog). `Agent.setFactScope(id, to:, by:)` takes one of `FactTarget`'s
`permanent`, `thread`, `session`; scope and temporal class move together, the fact enters the target book
(`FactBook.admit`) and the old copy is superseded, or, for a proposed permanent fact moved to `thread`,
changes class in place (`FactBook.retarget`). A move to `permanent` writes it as the person's (`approved` is
set, so it ranks with the person); it is audited as `fact.scope.changed`. Chat's `/fact ID SCOPE` calls it with
`by: .person`, and MCP's `set_fact_scope` with `by: .caller`, refusing `permanent` and `p…` ids in the
request decoder. After each turn `Agent.Reply.facts` holds the facts the turn recorded or changed
(`Agent.turnFactIDs`, reset when a turn starts), which chat prints as a one-line note, `wisp chat --json`
adds to the turn's end (and as a `note`), and `respond` returns as `structuredContent.facts`.

### Risk classification and approval

`ApprovalGate` (an actor, one per conversation) takes an `ApprovalThreshold` (a level, or `never`) and runs a `RiskClassifier` (`CompositeRiskClassifier` over
`RuleRiskClassifier` and `ModelRiskClassifier`) and, at or above the configured threshold, asks an
`Approver` (`TerminalApprover`, `DenyingApprover`, `AutoApprover`, `JSONApprover`, or, under `wisp mcp`,
`OutOfBandApprover` with the `ElicitationApprover` beside it). The gate calls `decide(_:audit:)` with the
asking conversation's log, and puts the conversation's id on the request (`ApprovalRequest.thread`), so an
approver that does work of its own (filing a request, posting a banner) audits it where the question was
asked.

**Approval through another face** ([ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)). Under `wisp mcp`,
`Session.mcpApprover` composes `OutOfBandApprover` from the configuration: it files the request in the
`PendingApprovals` channel (`~/.wisp/pending`, a directory of user-only files, each request bound to its
command, directory, thread, and server process by a SHA-256), posts a notification through the MCP host's
routes, and races two legs: a 200 ms poll of the channel for an answer file, and, when the client has it,
the elicitation dialog. The first answer settles the race; the other leg is cancelled without being
awaited (a dialog in flight ignores cancellation, as `Timeout` records), the request file removed or the
dialog withdrawn with `notifications/cancelled`, whose JSON-RPC id the server's `CompatibilityTransport`
learned from the dialog's `_meta` key (`ElicitationTracker`). A leg that fails leaves the other asking;
cancelling the call settles the race as abandoned. Answers come from other processes:
`wisp approvals approve|deny` writes the answer file, and `wisp chat --json`'s `PendingRelay` shows a
front end that declared `approve-mcp` each waiting request and writes its answer. With
`approval.outOfBand` off, `ElicitationOnly` asks through the dialog alone.
`CommandRunner` consults the gate after the policy check. See [approval.md](approval.md) and
[ADR 0011](decisions/0011-risk-classifier-and-approval.md). The model beside the rules is
`CoreMLRiskClassifier` (a Core ML text classifier under contract 1 or 2; the default, with the version
the release ships, ADR 0041) or `ModelRiskClassifier` (the on-device language model), chosen by
`approval.classifier`, and a session wraps whichever it
uses in `TimedRiskClassifier` and `CachingRiskClassifier`. `RiskClassifierTraining` trains a contract-2
model with Create ML from `RiskExample`s (the bundled `Resources/risk-examples.tsv`, a file, or
`RiskExamples.fromAudit`), and `RiskMeasurement` measures any classifier's accuracy and latency; `wisp
classifier` is their CLI ([ADR 0038](decisions/0038-fast-specialised-classifiers.md)).
`KnownSafeCommands` is the rules' short list of read-only commands: a verdict it gives is known safe
(`RiskAssessment.isKnownSafe`), and `CompositeRiskClassifier` then does not ask the model. `ClassifierStore`
keeps the versions under `~/.wisp/classifiers/risk`, one directory each with a read-only
`model.mlmodel` and a `manifest.json` of its training and measurements; `ShippedClassifier` is the
release's default, embedded from `Resources/risk-default.json` and installed as `risk@X.Y.Z-default` by
`installDefault()` when a session or `wisp classifier` first needs it. `TrainingSplit` parses the sets
under `training/`, deals them into parts by family, and finds overlaps between parts, for `wisp
classifier split` and `TrainingSetsTests`.

### Audit and diagnostics

`AuditLog` records `AuditEvent`s for one session through an `AuditSink` (`FileAuditSink` with rotation,
`MemoryAuditSink` for tests). `AuditedTool` wraps every registered tool; `Agent`, `CommandRunner`, and
`WispServer` record at their boundaries; the CLI records session start and end. `Diagnostics` wraps
`os.Logger` per category with optional stderr mirroring. See [logging.md](logging.md) and
[ADR 0010](decisions/0010-audit-and-diagnostic-logging.md). Every event has its own random `id`, which
`AuditLog.record` returns as an `AuditReference`. Every `WispThread` tees its audit into a
`ReceiptCollector`, for the `respond` receipt, an `EventRelay`, which passes events to whoever is
listening at the moment, and a `ToolEventTrail`, which the agent links its store's tool entries to. The MCP server listens while a call that carried a `progressToken` runs.
`AuditTail` follows the log file, across rotation, for `wisp logs --follow`. `AuditLog.event(_:)` reads one
event back by its reference when the sink can (`AuditReader`), which is how `memory`'s recall reaches an
entry's verbatim content.

### `Session` and `WispThread`

`Session.begin` is the one place an entry point's flags become a running configuration: it loads
`config.json`, applies `--instructions`, `--model`, and `--unsafe`, checks `--tool` names, opens the
audit log and the `ApprovalStore`, creates the `SessionApprovals` set and the risk classifier, and
records `session.start` with the same fields for `respond`, `chat`, and `mcp`. Anything the user should
see about the set-up (the `--unsafe` warning, the off-device model note) comes back as `notes` for the
face to print; library code never writes to stderr.

What a session builds from its config is injected through `Session.Dependencies`: `live` makes the
classifier `approval.classifier` names (the on-device model, or a Core ML model resolved by
`Session.coremlModelURL`, the shipped default when none is set) and appends to the audit file; `testing()` is
rules only with a memory sink. Every unit test passes `testing()`, which is how "tests never need the
model" holds for sessions as well as for gates.

A `WispThread` is one gate plus the tools wired to it and the `Prompting` the agent starts with, built by
one function for every face of wisp. `Prompting` renders three layers into the framework's instructions:
wisp's own system prompt (the file `Resources/system-prompt.md`, embedded at build time by the
`EmbedSystemPrompt` plugin), the operator's `systemPromptExtension` from config, and the caller's
conversation instructions; see [ADR 0017](decisions/0017-three-layer-instructions.md).
What differs between faces is what the face that owns the person's screen can do for a tool, so it is
given when a conversation is opened, not when the session begins, as a `SessionHost`
([ADR 0044](decisions/0044-host-effects.md); Foundation already has a `Host`). A host carries the face's
effects: the command `approver` (request and answer) and the notification routes (fire and forget),
beside the session's `Notifier`. `Session.host(approver:face:)` builds one for each face; the gate asks
`host.approver`, and `NotifyTool`, `wisp notify`, and `wisp watch` post through `host.notify`, so no tool
calls a face directly. A `--yes` request replaces the approver with `AutoApprover` inside the core, so the
flag means the same everywhere. The faces are overlays on this core:

| Face | How it opens its conversation | Notification routes (`NotificationRoutes.Face`) |
| --- | --- | --- |
| `respond` | `session.openAgent(host:)` with a denying approver that explains `--yes` and `chat` | `.terminal` |
| `chat` | `session.openAgent(host:transcript:)` with the terminal approver, resumable; `/model` reopens with `store:` so the new model continues the conversation's store | `.terminal` |
| `chat --json` | The same, with `JSONApprover` | `.frontEnd`: the front end when its `hello` declared `notify` |
| `mcp` | `session.thread(id:host:…)` per `thread_id` with `Session.mcpApprover` (the out-of-band channel and the client's dialog, ADR 0046), its own audit session (recording its own `session.start`), gate, tools, and optional instruction, tool, and model overrides; the server keeps the thread, gate, and audit log together as one `OpenThread` in the `ThreadRegistry`, so they are created and dropped together | `.mcp`: the process routes only |

`Notifier` applies the off switch, the bounds, and the per-minute limit across the process, then hands the
bounded message to the face's `NotificationRoutes`, which try ADR 0044's routes in order and return the
first that works with the reasons the earlier ones were skipped: `host` (the front end's `notify` line),
`terminal` (the escape sequence `TerminalNotification` builds for the terminal `TERM_PROGRAM` or `TERM`
names, written to `/dev/tty`; only the `.terminal` face, since under `--json` the front end and under MCP
the client own the terminal), `app` (`display notification` sent to `__CFBundleIdentifier`'s app, only with
`notifications.viaTerminalApp`), and `osascript`. The plan is a pure function of the face, the environment,
and the setting (`NotificationRoutes.steps`), which the tests and `wisp doctor` read; the terminal writer
and the `osascript` runner are injected.

Every conversation of a session shares its config, `ApprovalStore`, and `SessionApprovals`, so a
"this project" answer on one MCP thread is written once and a "this session" answer covers every thread.
The MCP tests build real sessions over a scratch home and check that two threads share one store.

### `Introspection`

Read-only views of wisp's own state, built once and rendered three ways: the model's `inspect` tool,
the MCP `wisp://config|status|approvals|audit` resources, and `wisp config` and `wisp logs`. It
holds the home, the effective config, the approval store, and a status closure the `WispThread`
supplies (session id, turn, tools, model, session approvals); the MCP server adds the thread count, a link to
`wisp://threads`, and the standing-approval count to the status resource. Audit reads go through the same file walk `logs`
uses. See [ADR 0018](decisions/0018-introspection.md).

### Home, config, transcripts

`Home` resolves `$WISP_HOME` or `~/.wisp` and lays out `config.json`, `approvals.json`, `facts.json`, `logs/`,
`transcripts/`, `context/`, and `classifiers/`.
`Config` is optional JSON (system prompt extension, model, `run_command` limits, MCP thread capacity) with defaults applied by
`resolved`. `TranscriptStore` saves and loads transcripts as `<name>.json`, with the store's links to the audit log in
`<name>.store`, which resuming requires. Commands that write (audit log,
transcripts, the doctor's write probe) call `Home.ensure()`; `tools` and `logs` never create the directory.

### `ToolRegistry`

A static list, `all`, is the single source of truth for what the model can see. `select(_:)` resolves names
from the CLI and reports unknown ones so the CLI can fail before touching the model.

### Tools

Each tool is a `struct` conforming to `FoundationModels.Tool` under `harness/Sources/WispCore/Tools/`:

- `name` is the identifier the model uses; keep it `snake_case` and stable.
- `description` is prompt text; write it for the model, not for humans.
- `Arguments` is `@Generable`; use `@Guide` on each property to constrain what the model produces.
- `call(arguments:)` does the work. Keep the formatting logic in a `static` helper so it is testable without the
  model (see `CurrentDateTool.format`).

`CurrentDateTool` is the reference implementation: the on-device model has no clock, so this is the smallest
tool that changes an answer.

`ReadFileTool` pages a text file: `FileReader` streams the file in chunks through a `LineScanner`, skips to
the requested line, and stops when the page or its byte budget is full, so cost is bounded by the page, not
the file. The rendering ends with an offset hint the model follows to continue.

`EditFileTool` is its counterpart: `FileWriter` writes, appends, or replaces one exact match, and refuses
any path outside `CommandPolicy.writableRoots`, the list the Seatbelt profile is built from, so the
tool can change no more than a command could. Each edit is cleared by the gate as
`edit_file <mode> <path>` and recorded as `file.write` ([ADR 0024](decisions/0024-edit-file.md)). The
tools do not share one control path: `run_command` passes the policy patterns, the gate, and Seatbelt;
`edit_file` the writable list and the gate; `read_file` the gate's rules only; `inspect` and
`current_date` none; `memory` reads only the conversation's record and the audit log and writes only the
model's own facts, below the person's and the tools', so none either.
`NotifyTool` posts through the session's host (above), bounded, rate-limited, and
audited as `notification` with the route taken, without the gate
([ADR 0030](decisions/0030-notifications.md), [ADR 0044](decisions/0044-host-effects.md)).

`RunCommandTool` is the generic exec tool. It delegates to `CommandRunner`, which checks the
`CommandPolicy` patterns, consults `ApprovalGate` (rules plus a classifier, the shipped Core ML one by default, ask at
`moderate` and above through an `Approver` per entry point), then spawns `/bin/sh -c` in its own process
group (`posix_spawn`) under `sandbox-exec` with a profile rooted at the launch directory, captures stdout
and stderr separately, kills the whole group on timeout, and keeps only the tail of each stream. The
rendering (`Outcome.rendered`) is what the model sees; policy denials and refusals are rendered too rather
than thrown. See [ADR 0009](decisions/0009-command-policy-and-sandbox.md).

### MCP server

`WispMCP.WispServer` serves stdio MCP (`wisp mcp`) through `CompatibilityTransport`, which
normalises messages the SDK cannot decode although the protocol allows them (see `docs/mcp.md`). It advertises `respond`, the condensing tools (`triage`,
`summarise_diff`, `draft_change`, `scan_secrets`, `redact`, `condense_log`, `json_shape`, `dependency_audit`, `flaky_tests`, `hot_paths`), `set_fact_scope`, and `close_thread` from `ToolCatalog`, whose JSON Schemas and descriptions are the contract other harnesses see; wisp's own tools
are reachable only through `respond`, and are described to clients by the `wisp://tools` resources,
generated from `ToolRegistry.descriptions` (schema from each tool's `GenerationSchema`, limits and example
prompt from the tool's own `WispTool` conformance, so a changed default shows up in the catalogue).
The request types decode and validate arguments as pure, testable values; see
[ADR 0006](decisions/0006-mcp-server-over-stdio.md).

`respond` runs on a conversation thread. `ThreadRegistry` is an actor keeping threads by id with LRU eviction;
`ThreadActor` is an actor owning one `Agent`, so calls on a thread serialise while threads run
concurrently. Results carry `structuredContent.thread_id`; see
[ADR 0007](decisions/0007-conversation-threads.md). Each `WispThread` tees its audit log into a
`ReceiptCollector`, a bounded in-memory sink; after a turn the server folds that turn's events into a
`Receipt` for `structuredContent.receipt` ([ADR 0021](decisions/0021-receipts.md)), so the result and
the log never disagree. The same events fold into `TurnCalls` for `structuredContent.calls` (the
proposal's D9): each tool call with its output as the tool returned it, inline up to `inlineOutputBytes`
and otherwise as a `wisp://threads/{thread_id}/output/{id}` reference, which the server resolves from the audit
log by the `tool.result` event's id, the reference the conversation's store keeps for that output.
Everything else about a thread is under `wisp://threads` too (`ThreadResources`, `ContextResources`): a
`ThreadDirectory` remembers each thread the server opened (model, tools, turns, open or closed, bounded
at 256 records) so its summary, tool calls, and audit stay readable after it closes, and the context
resources compose a live thread's context from its agent's store through `RespondingThread.context`, at
no model cost (the proposal's D12). `ThreadRegistry.peek` reads a thread without marking it used. A call may give a JSON Schema; `OutputSchema` converts the accepted subset to a
`DynamicGenerationSchema`, `Agent.respond(to:schema:)` runs guided generation after checking the model
declares it, and the reply's JSON is parsed into `structuredContent.output`
([ADR 0022](decisions/0022-structured-output.md)). `scan_secrets` and `redact` share `SecretScanner` (the rules), `Redactor` (numbered markers), and
`ModelSweep` (the opt-in model pass over rule-redacted text, keeping only values that occur exactly)
with `wisp scan` and `wisp redact` ([ADR 0031](decisions/0031-secret-scanning-and-redaction.md)).
A chunk whose model turn fails twice is reported in `failedChunks` and keeps its rule findings. With
personal data asked for, `SecretScan` also runs `PersonalDataClassifier` over the lines nothing else
flagged. It is a Core ML model embedded from `Resources/personal-default.json`, trained by
`PersonalDataTraining` through `wisp classifier ship --task personal`
([ADR 0042](decisions/0042-personal-data-classifier.md)).
`condense_log` (`LogDigest`, `CrashReport`) and `json_shape` (`JSONShape`) are deterministic: templates
and ranking for logs, a parsed `.ips` for crashes, a merged outline for JSON
([ADR 0032](decisions/0032-log-and-json-condensers.md)). `dependency_audit` (`DependencyAudit`),
`flaky_tests` (`FlakyTests`), and `hot_paths` (`HotPaths`) are deterministic too, and `Triage` runs
`KnownFailures` on each chunk before the model, which sees only what those patterns do not explain
([ADR 0039](decisions/0039-exact-condensers.md)). The server's `condense` helper gives every condensing
tool its conversation, runner, gate, and capture.
`ModelRouting` chooses a model by input size from `Measurements.embedded` and the config's ladder, before
anything runs; `ChangeDraft.route` applies it, honouring an explicit model and passing over a rung that
cannot open ([ADR 0037](decisions/0037-routing-by-input-size.md)). An Ollama model's window is chosen when it is
resolved: `ContextSizing` reads its shape from `/api/show` and sizes the window to what `MemoryState` says
the Mac has free ([ADR 0043](decisions/0043-context-window-from-memory.md)), and the executor asks for
that window on every request. `ModelRouting.forTask` gives a task's
model pass its default when the caller names none: `ModelRouting.taskDefaults` (`secrets: system`,
measured best), overridden by `routing.tasks`. The choice is audited as `model.routed`.
While a call runs, `WispServer.relaying` turns the conversation's events into
`notifications/progress` for a caller that asked, using `ChatEvents.progress` for the text.
`draft_change` and `wisp draft` are `ChangeDraft`: a `DiffSummary` report, then one schema-shaped turn,
with the subject and body shape applied in code ([ADR 0035](decisions/0035-change-drafts.md)).
A session's model classifier is wrapped as `CachingRiskClassifier(TimedRiskClassifier(…))`: verdicts are
kept per command line and directory, and only real classifications are timed for `/stats`
([approval.md](approval.md)).
`CustomTool` turns a `tools.custom` definition from the config into a tool whose `GenerationSchema` is
built at run time and whose calls run the substituted line through the registry's `CommandRunner`, gate
included; `ToolRegistry` appends them after the built-ins and drops `tools.disabled`
([ADR 0036](decisions/0036-custom-tools.md)).
`system_info` (`SystemInfo`, `ProcessTable`) answers questions about the Mac from fixed read-only probes
through the conversation's runner without the gate, and from `libproc` for processes, since Seatbelt
will not run the setuid `ps` ([ADR 0034](decisions/0034-system-info.md)).
`wisp watch` is `Watcher` in `WispCore/Session`: a loop over an `AsyncStream` of triggers (start,
FSEvents changes from `FileWatcher`, an interval) whose running, triaging, notifying, and reporting are
injected, so it is tested without time or the file system; `TriggerSettler` produces the triggers and
settles a burst of file changes into one after a quiet period, on an injected `Clock`; its command is cleared once through
`CommandRunner.authorize`, which returns an `Authorized` line that reruns without the gate but with the
policy, sandbox, and audit ([ADR 0033](decisions/0033-watch-mode.md)).
`triage` and `summarise_diff` were the first condensing tools; `DiffSummary` chunks a diff at file
boundaries and joins the model's summaries and flags onto the file list the diff itself gives. `triage` was the first: `Triage`
in `WispCore/Condense` captures a command's output through `CommandRunner` (same policy, gate,
sandbox, audit) or reads a file after the gate clears it, chunks it, judges each chunk through a
schema-shaped turn on a conversation of its own, and merges the findings
([ADR 0023](decisions/0023-condensing-tools.md)).

A `respond` call goes from `WispServer` to the `ThreadRegistry`, which finds or creates the
`ThreadActor` for its `thread_id`, and on to that thread's `Agent`; `close_thread` removes the
thread from the store. The overview diagram above shows the rest of the path.

### CLI

`wisp` mirrors `fm respond` where semantics match: positional prompt or stdin, `--instructions`,
`--[no-]stream`, repeatable `--tool`. `wisp chat` is a line-oriented REPL with slash commands parsed by
`ChatInput` (`/help`, `/tools`, `/tokens`, `/inspect`, `/status`, `/approvals`, `/audit`, `/fact`, `/task`, `/last`,
`/show`, `/models`, `/model`, `/stats`, `/history`, `/config`, `/save`, `/new`, `/quit`; `ChatInput.helpEntries` is the
list `/help` prints and the table the parser looks each command word up in), `--resume <name>`, and `--save <name>`.
`wisp tools` lists the registry. `wisp mcp` serves MCP on stdio. Instructions default to `config.json`.
Exit codes follow swift-argument-parser conventions (64 for usage errors). The chat loop itself is
`ChatLoop` in `WispCore`, with its input and output injected, so the executable only wires the
terminal to it and `ChatLoopTests` runs the whole loop over a scripted model. Chat shows tool activity
live through `ChatEvents.Tap`, an `AuditSink` the conversation is opened with (`Session.openAgent(observer:)`
tees it beside the log and the receipt collector), so the lines the user sees are rendered from the
audited events, each tool's output included (`ChatEvents.shownOutput`, folded past `shownOutputLines`;
`ChatView.output` finds one again for `/show`); `ChatView` carries a view shown whole (`/inspect context next`, `N`, `turns`),
which the plain chat prints and `--json` sends as a `view` line through `ChatLoop.IO.view`; `ChatStatus` draws the status line above each prompt; `Style` applies colour only on a
terminal. `TextTable` pads chat output such as `/models` and `/stats` into columns, because tabs drift
in a terminal and in the TUI. `TerminalTable` and `ListingLayout` lay out `wisp tools`, `models`, and
`approvals` like `wisp --help` when standard output is a terminal, wrapped to its width, and keep the
tab-separated lines when it is piped. `/stats` reads `CallStats`, a fixed-size ring (`Mutex`, 256 calls) that
`Session.begin` creates and every `WispThread` hands to its `Agent`, which records each turn's time,
outcome, and reported prompt tokens; the classifier is wrapped in `TimedRiskClassifier` unless it is the
rules alone, and a classifier's fallback verdict carries `RiskAssessment.failureKey` so it counts as a
failure. `ChatActivity` follows a turn's events to say what it is doing now (waiting for the model,
running a command, waiting for approval). The terminal chat redraws that as a working line; `--json`
sends it as `activity` lines. `ChatLoop.history` keeps the latest 100 typed lines for `/history`; `wisp-tui` keeps its own
list for Up and Down. `wisp chat --json` is the same loop with its IO mapped onto a JSON Lines protocol
(`ChatProtocol`, `LineRouter`, `JSONApprover`), so a front end in another process, `tools/wisp-tui`,
can own the screen while the session stays here. The front end's optional first line, `hello`, declares
the host effects it carries; `LineRouter` keeps it (`declares`), the host's notification routes ask it at
each notification, and `JSONApprover` denies without asking when a `hello` left out `approve`. A
`hello` that declares `approve-mcp` starts a `PendingRelay`, which sends the commands waiting in
`wisp mcp` servers as `approval` lines (`source: "mcp"`) and `withdrawn` when they stop waiting. `/config` shows the configuration as YAML through
`YAMLText`; `/config set` and `wisp config set` go through
`ConfigSettings` (the settings that can change, and what each takes) and `ConfigEdit` (one path set or
removed, the result validated as start-up would before it is written); a chat command that needs an
answer asks a `ChatChoice` through `ChatLoop.IO.choose`, a numbered list in the plain chat and a
`choice` line in `--json`; and `ChatCompletion` gives Tab's candidates from the same catalogue, answered
beside the loop through `LineRouter.onComplete` ([ADR 0040](decisions/0040-config-from-chat.md)).

## Error handling

Errors are typed enums named `Failure`, one per subsystem, conforming to `Error`, `CustomStringConvertible`,
and `Equatable`, and they keep the underlying cause typed where a caller could act on it
(`Session.Failure.malformedConfig` carries a `ConfigProblem`). Library code never prints or calls
`fatalError`; the CLI is the only place that renders errors to stderr, and `Wisp.usage` is the one
place a bad-input failure from the core becomes a usage error (exit 64). Entry points are the closed
`EntryPoint` enum, so the values `session.start` and the approval store record cannot drift from the docs.

## Concurrency

Swift 6 strict concurrency is enabled. `LanguageModelSession` is not `Sendable`, so `Agent` is a plain
`final class` used from one task at a time, and its async methods are `nonisolated(nonsending)` so they run
in the caller's isolation. That is what lets `ThreadActor` (an actor) own an `Agent`. Do not move
session work into detached tasks.

Actor or `Mutex` is chosen by one rule. A type is an actor when its operations suspend (awaiting a human,
the model, or another actor) or when a change is a multi-step sequence that must not interleave, such as
the approval store's load-mutate-save: `ApprovalGate`, `ApprovalStore`, `ThreadRegistry`,
`ThreadActor`. A type is a `final class` holding a `Mutex` when every operation is a short
synchronous critical section that callers must not have to `await`: `SessionApprovals`, `TurnClock`,
`AuditLog`, the sinks, `OutputBuffer`, `ClientCapabilityFlags`.

## Visibility

`WispCore` is an implementation library for the two executables, not a published API. A declaration is
`public` when `WispMCP` or `wisp` calls it, or when it is an extension point a new component conforms
to (`WispTool`, `Approver`, `RiskClassifier`, `AuditSink`) or a type such a public signature exposes.
Everything else is internal; tests reach it through `@testable import`.

## Extension points

- New in-process tool: add a file under `Tools/`, append to `ToolRegistry.all`, add a test for its pure helper.
- New Rust tool binary: `cargo new --bin` under `tools/`, list it in the workspace, then either let the model
  reach it through `run_command` or give it a dedicated Swift `Tool` whose description tells the model when to
  use it.
- New MCP tool: add a `Tool` to `ToolCatalog`, a request type, and a case in `WispServer.call`.
- Thread persistence or context management: extend `ThreadActor`; record the choice in an ADR.
- Session persistence and structured output have shipped (`TranscriptStore`, `Agent.respond(to:schema:)`); a
  new output shape goes through `OutputSchema`.
