# wisp documentation

| Document | Purpose |
| --- | --- |
| [trust.md](trust.md) | What wisp can do to your Mac, what leaves it, what it remembers, how to see and undo |
| [objective.md](objective.md) | What wisp is for and what "done" looks like |
| [wisp.md](wisp.md) | Command reference: subcommands, flags, `~/.wisp`, `config.json`, exit codes |
| [tools/](tools/README.md) | One page per model-facing tool: contract, result format, limits |
| [measurements.md](measurements.md) | What the eval harness found each delegated task achieves, how it is recorded, and where it is published |
| [mcp.md](mcp.md) | wisp as an MCP server: client setup, `respond`, the condensing tools, structured output, receipts, progress, errors |
| [design.md](design.md) | Architecture: components, data flow, extension points |
| [fm-cli.md](fm-cli.md) | What the Apple `fm` command family does and does not offer, as observed |
| [local-model-evaluation.md](local-model-evaluation.md) | Local-model research, candidate shortlist, and agreed workload/delegation evaluation design |
| [local-model-installation.md](local-model-installation.md) | Selected model revisions, local installation, offline smoke results, and remaining integration work |
| [on-device-ai-todo.md](on-device-ai-todo.md) | Draft backlog for four on-device AI use cases, model routing, and prompt-linked transcript/audit records |
| [model-controls.md](model-controls.md) | Draft common controls for reasoning mode, effort, native speed mode, performance preferences, and reasoning output |
| [approval.md](approval.md) | Risk classification (rules plus the shipped Core ML classifier by default, or the on-device model), classifier versions, approval scopes and persistence, eval results |
| [logging.md](logging.md) | The audit log (format, kinds, `wisp logs`) and diagnostics (`WISP_LOG`, unified logging) |
| [context-management.md](context-management.md) | The small context window: framework APIs, what wisp does, design rules |
| [policy-and-sandboxing.md](policy-and-sandboxing.md) | Survey of tool policy and sandboxing options and which layers are implemented |
| [decisions/0013-model-selection.md](decisions/0013-model-selection.md) | Which model a session runs on (`system` or `private-cloud`), and why the default stays on device |
| [decisions/0015-per-command-approval.md](decisions/0015-per-command-approval.md) | Approve each simple command in a line, remembered by its program |
| [decisions/0014-persisted-approvals.md](decisions/0014-persisted-approvals.md) | Approvals have four scopes; project and always persist under ~/.wisp |
| [decisions/0012-homebrew-release.md](decisions/0012-homebrew-release.md) | Release through a Homebrew tap, unsigned, semver from 0.1.0 |
| [decisions/0011-risk-classifier-and-approval.md](decisions/0011-risk-classifier-and-approval.md) | Classify command risk with rules plus the on-device model, and ask above a threshold |
| [decisions/0010-audit-and-diagnostic-logging.md](decisions/0010-audit-and-diagnostic-logging.md) | Verbatim JSON Lines audit log plus unified-logging diagnostics |
| [decisions/0009-command-policy-and-sandbox.md](decisions/0009-command-policy-and-sandbox.md) | run_command is governed by a CommandPolicy and a Seatbelt sandbox |
| [decisions/0008-context-condensation.md](decisions/0008-context-condensation.md) | Recover from context overflow by condensing to recent turns |
| [decisions/0007-conversation-threads.md](decisions/0007-conversation-threads.md) | Conversation threads over MCP |
| [decisions/0006-mcp-server-over-stdio.md](decisions/0006-mcp-server-over-stdio.md) | wisp is an MCP server over stdio |
| [decisions/0005-tools-as-plain-binaries.md](decisions/0005-tools-as-plain-binaries.md) | Tools are plain binaries; the harness owns the model-facing schema |
| [decisions/0004-enforced-standards.md](decisions/0004-enforced-standards.md) | Standards are enforced by tooling, shared between hook and CI |
| [decisions/0003-callback-streaming.md](decisions/0003-callback-streaming.md) | Stream via a delta callback, not an AsyncSequence wrapper |
| [decisions/0002-macos-27-baseline.md](decisions/0002-macos-27-baseline.md) | macOS 27 is the platform baseline |
| [decisions/0001-swift-and-foundationmodels.md](decisions/0001-swift-and-foundationmodels.md) | Implement wisp in Swift, linking FoundationModels directly |
| [decisions/0030-notifications.md](decisions/0030-notifications.md) | Notifications through osascript with the text in argv, bounded, rate-limited, and audited, without approval |
| [decisions/0031-secret-scanning-and-redaction.md](decisions/0031-secret-scanning-and-redaction.md) | Secret scanning and redaction: rules first, masked findings and numbered markers, an opt-in model pass over rule-redacted text |
| [decisions/0032-log-and-json-condensers.md](decisions/0032-log-and-json-condensers.md) | Log and JSON condensers are deterministic: templates ranked by severity, parsed crash reports, merged JSON outlines |
| [decisions/0033-watch-mode.md](decisions/0033-watch-mode.md) | Watch mode reruns a command on file changes and notifies when its outcome turns, triaging new failures |
| [decisions/0034-system-info.md](decisions/0034-system-info.md) | `system_info` answers questions about the Mac with fixed read-only probes and `libproc`, without the approval gate |
| [decisions/0035-change-drafts.md](decisions/0035-change-drafts.md) | Change drafts are written from the diff summary, with the subject and body shape enforced in code |
| [decisions/0036-custom-tools.md](decisions/0036-custom-tools.md) | Custom tools are command templates in the user's own config, run through `run_command`'s gate |
| [decisions/0037-routing-by-input-size.md](decisions/0037-routing-by-input-size.md) | Route a task to a model by the size of its input, from measured size bands and a configured ladder |
| [decisions/0038-fast-specialised-classifiers.md](decisions/0038-fast-specialised-classifiers.md) | Classifiers are tasks served by fast, specialised models, measured for speed; `wisp classifier`, versions with a fixed shipped default, train/dev/test sets under `training/`, the rules' read-only list |
| [decisions/0039-exact-condensers.md](decisions/0039-exact-condensers.md) | Triage reads known failure formats exactly first; `dependency_audit`, `flaky_tests`, and `hot_paths` without a model |
| [decisions/0040-config-from-chat.md](decisions/0040-config-from-chat.md) | Change the configuration from chat or `wisp config set`, checked, audited, and only by a person |
| [decisions/0041-shipped-classifier-is-the-default.md](decisions/0041-shipped-classifier-is-the-default.md) | The fast Core ML classifier each release ships is the default risk classifier, not the on-device model |
| [decisions/0042-personal-data-classifier.md](decisions/0042-personal-data-classifier.md) | A personal-data classifier flags lines beside the rules in `scan_secrets`; the trained file, not the training, ships |
| [decisions/0029-tui-front-end.md](decisions/0029-tui-front-end.md) | The terminal chat is a Rust front end (`wisp-tui`, ratatui) over a headless `wisp chat --json`; one palette for both faces |
| [decisions/0028-rename-to-wisp.md](decisions/0028-rename-to-wisp.md) | The project is wisp; one mechanical rename, no compatibility layer, a new Homebrew tap |
| [decisions/0027-verb-patterns.md](decisions/0027-verb-patterns.md) | Approval patterns include the verb for programs like git and cargo, from an embedded list; old patterns still count |
| [decisions/0026-task-catalogue.md](decisions/0026-task-catalogue.md) | Eval results ship with the tool catalogue as measurements, recorded by the eval run and embedded at build time |
| [decisions/0025-context-estimation.md](decisions/0025-context-estimation.md) | The agent condenses ahead of a known window from the usage the runtime reports, because local runtimes truncate silently |
| [decisions/0024-edit-file.md](decisions/0024-edit-file.md) | `edit_file` writes inside the sandbox's writable set, needs approval like a command, and replaces only an exact single match |
| [decisions/0023-condensing-tools.md](decisions/0023-condensing-tools.md) | Purpose-built MCP tools condense local content on device; `triage` runs or reads build output and returns only the failures, amending ADR 0006 |
| [decisions/0022-structured-output.md](decisions/0022-structured-output.md) | A caller's JSON Schema shapes the reply through guided generation, in an accepted subset, refused when the model does not declare it |
| [decisions/0021-receipts.md](decisions/0021-receipts.md) | `respond` returns a receipt of the turn, derived from the audit events rather than collected separately |
| [decisions/0020-coreml-risk-classifier.md](decisions/0020-coreml-risk-classifier.md) | A Core ML text classifier can judge commands behind a versioned contract, beside the rules, never lowering a level |
| [decisions/0019-model-backends.md](decisions/0019-model-backends.md) | Model backends are a registry keyed by scheme; capabilities are declared by the framework, the runtime, or config, and checked before a session opens |
| [decisions/0018-introspection.md](decisions/0018-introspection.md) | wisp's own config, status, approvals, and audit are readable, read-only, through the model's `inspect` tool, MCP resources, and the CLI |
| [decisions/0017-three-layer-instructions.md](decisions/0017-three-layer-instructions.md) | wisp's system prompt (a resource file), the operator's extension, and the caller's instructions, rendered in order |
| [decisions/0016-local-runtimes-through-an-executor.md](decisions/0016-local-runtimes-through-an-executor.md) | Locally installed models plug in through a wisp-supplied executor; what the spike measured; `ollama:<name>` built |
| [release.md](release.md) | How a release is cut: tag, tarball, GitHub release, Homebrew tap formula |
| [backlog.md](backlog.md) | Agreed work not yet started: further condensing tools, sampling, deferred backends |
| [engineering.md](engineering.md) | Standards, tooling, the pre-commit gate, and CI |
| [backends.md](backends.md) | Model backends: Apple's, Ollama, Core AI, MLX; asset preparation, naming, declared capabilities, errors |
| [decisions/](decisions/) | Architecture Decision Records, one per significant decision |
| [proposals/2026-09-22-tui-spike.md](proposals/2026-09-22-tui-spike.md) | Spike: a ratatui front end over a headless `wisp chat --json`; what was built, what was answered, what needs a real terminal |
| [proposals/2026-09-29-layered-context.md](proposals/2026-09-29-layered-context.md) | For review: stored, active, and shown views of a conversation; a context composed for each request from literal turns, a summary, facts, and recall; display decoupled from context by output handling |
| [proposals/2026-09-20-escalations.md](proposals/2026-09-20-escalations.md) | For review: two escalation verbs (approval, inquiry) and a choice of channels, including a non-blocking hand-off to the calling agent |
| [reviews/](reviews/) | Dated code and documentation reviews with their todo lists and status |

Conventions: documentation is updated in the same change as the code it describes (see the definition of done
in [engineering.md](engineering.md)). Documents describe the current state and are edited in place. Decisions are append-only; a
superseded ADR keeps its file and gets a `Superseded by` line. Add an ADR whenever a choice would be
non-obvious to a newcomer or expensive to reverse.
