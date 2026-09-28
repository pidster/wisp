# Changelog

Notable changes per release, written for people who run wisp. The release script publishes the
section for the version being cut as the GitHub release notes and refuses to release without one.
Keep an `Unreleased` section at the top while working; the version-bump commit renames it.

## Unreleased

Changed:

- `wisp scan`, `wisp redact`, `scan_secrets`, and `redact` find more credentials by rule, without the
  model:
  - `Authorization` headers and session cookies;
  - unquoted assignments to credential names (`db_pass: …`, `X-Api-Key: …`);
  - passwords given to `mysql -p`, `curl -u`, `docker login -p`, `sshpass`, and `--password` flags;
  - password hashes, PGP key blocks, and signed URLs;
  - more provider tokens (GitLab, PyPI, Docker, npm, Vault, Google OAuth, and others).

  A password in a URL is now reported as a secret, not as an email address. Email addresses on any
  domain reserved for examples (`example.com`, `example.net`, `example.org`, their subdomains, and
  `.test`, `.example`, `.invalid`) are no longer reported as personal data; before, only
  `example.com` and `example.org` were skipped. On the secrets test set the
  rules find 32% of secrets, up from 13%, with no more false alarms.
- The thorough pass of `scan`, `redact`, `scan_secrets`, and `redact` runs on the on-device model
  unless you name another, whatever `config.json`'s `model` is. On the secrets test set it did better
  there than `ollama:granite4.1:8b` (macro-F1 0.67 against 0.56). `routing.tasks.secrets` sets a
  different default (`wisp config set routing.tasks.secrets <model>`), and each routed pass is audited
  as `model.routed`.

Added:

- `wisp scan --personal` and `scan_secrets` with `personal` find far more personal data, without the
  model. A small classifier shipped in the binary flags lines holding names, account holders, and
  addresses that the rules cannot recognise, shown as `personal-data (classifier)`. On the secrets test
  set it finds 62% of personal lines, against 12% for the rules alone, at about 2 ms a line. With
  `--thorough` too, 80% are found. `redact` does not use it yet.

- Watch what MCP clients have wisp do. In chat, `/audit sessions` lists the sessions in the audit log
  and how each began, and `/audit <id>` shows one session's latest events, such as a `respond` thread;
  Tab completes the ids. In a terminal, `wisp logs --follow` (`-f`) prints events as they are written,
  and can be narrowed with `--session`, `--kind`, and `--tool`.

Fixed:

- Chat's help said `/audit` shows this session's events; it shows the latest of every session.
- A thorough `scan_secrets`, `redact`, `wisp scan`, or `wisp redact` no longer fails as a whole when
  the model refuses or fails on one chunk, which the on-device model's guardrails sometimes do on text
  full of credentials. The turn is asked once more; if it fails again, that chunk is checked by rule
  only, its number is reported in `failedChunks`, and the rest of the text and every rule finding are
  kept.

## 0.13.2

Changed:

- The risk rules rate more dangerous commands dangerous:
  - credential reads: `kubectl config view --raw`, `kubectl … get secret -o yaml` with flags before
    `get`, `az keyvault secret show`, `gcloud secrets versions access`, `vault kv get`,
    `gpg --export-secret-keys`, `security find-generic-password -g`, and a credential echoed inside
    `sh -c '…'`;
  - publishing to a registry (`npm publish`, `cargo publish`, `mvn deploy`, `docker push`, and others),
    except as a dry run;
  - deleting remote storage (`aws s3 rb --force`, `aws s3 rm --recursive`);
  - `diskutil apfs deleteVolume`;
  - `git reflog expire`, `git gc --prune=now`, and `git checkout <ref> -- <paths>`.

  Measured by cross-validation over 403 dangerous commands, the gate rates 1.5% of them safe, down from
  4.2%, with no more prompts on safe commands.

Fixed:

- `git restore --staged`, which only unstages, no longer counts as discarding local changes.

## 0.13.1

Changed:

- The default risk classifier is the fast Core ML classifier this release ships (`approval.classifier:
  coreml`), not the on-device model: on 996 real commands it rates more commands exactly (817 against
  664), prompts on half as many safe ones, and answers in under a millisecond however busy the Mac is.
  A configuration that sets `approval.classifier` keeps its choice, and `approval.useModel: true` still
  means the on-device model. `wisp doctor` checks the classifier and names the shipped version.

Fixed:

- 0.13.0's published binary already had this default, but its source, notes, and docs did not; this
  release is the build that matches them. `scripts/release` now refuses to publish when the working
  tree or `HEAD` changes while it runs.

## 0.13.0

Added:

- Risk classifier versions: each release ships a default, `risk@X.Y.Z-default`, trained once, measured,
  and never changed, used by `approval.classifier: coreml` when no model is named, so a fast classifier
  needs no training. `wisp classifier train` adds a new version, `risk@X.Y.Z-local.<n>`, and never
  overwrites one; `wisp classifier list`, `use`, and `remove` manage them, and `measure` records each
  result in the version's manifest. Versions live in `~/.wisp/classifiers/risk`.
- `wisp classifier train` leaves out every example that overlaps `~/.wisp/classifiers/risk/held-out.tsv`
  or a file given with `--exclude`, so a test set of commands run on this Mac is never trained on.
- `/config` in chat shows the configuration as YAML; `wisp config` stays JSON.
- `wisp-tui` shows the lines you send in the scrollback like the input box, a shade darker, with its
  half-block strips above and below.
- Chat's commands follow the CLI's nouns: `/config get KEY` (and `wisp config get KEY`) shows one
  setting and whether it is set or the default; `/status`, `/approvals`, and `/audit` replace
  `/inspect status|approvals|audit`, `/approvals revoke [ID]` removes a standing approval at once, and
  `/inspect` stays as an alias. Tab completes the new words and approval ids.

Changed:

- The shipped risk classifier is trained from 2,061 examples, 1,075 of them real commands from
  development sessions, instead of 292 drafted ones. On a frozen set of 996 real commands, beside
  the rules, it rates 817 exactly, where the previous default rated 376.
- The risk rules rate printing a credential dangerous: `printenv` or `echo` of a variable named for a
  password, token, secret, or key, `env | grep` for them, `gh auth token`, `op read`, `aws configure get`
  of a secret, and `kubectl get secret -o yaml|json|jsonpath`. Checking whether one is set
  (`${TOKEN:+yes}`) or its length is not.
- The risk rules know a short list of read-only commands (`ls`, `cat`, `grep`, `git status`, `git log`,
  `git diff`, `--version`, and the like). For those the verdict is `safe` without asking a model
  classifier, so they cost no model call and never prompt. A command that writes, runs something
  else, or names a sensitive file is never on the list.

Fixed:

- Redirecting to `/dev/null` no longer counts as writing a file in the risk rules.
- The risk rules follow the training labels: building and testing the project (`swift test`, `cargo
  build`, `make`) no longer asks by itself, while `xcodebuild`, clean targets, and installs still
  do, and `python3 -m http.server` on every interface is dangerous, not moderate.
- The risk rules no longer take `git merge-base` for `git merge`, `git tag -l` for making a tag, or a
  program's `open(…)` or a word `at` inside a command for the `open` and `at` commands, so those read-only
  commands no longer ask for approval.
- Training a risk classifier uses every example and gives the same classifier from the same examples:
  Create ML held back a random slice of them for its own validation, so two trainings disagreed on about
  4% of commands.

## 0.12.0

Added:

- `/config set KEY VALUE` and `/config unset KEY` in chat, and `wisp config set` and `unset`, change
  `~/.wisp/config.json` without editing it: each value is checked against the setting, the file must
  still load, the rest of it is kept, and every change is audited. `/config list` and `wisp config list`
  show the settings that can be changed and their values. A change that weakens the approval gate or the
  audit is flagged.
- `/config set` offers what you leave out: the settings, then the setting's choices, including the
  models this Mac can run and the trained Core ML models on disk. `wisp-tui` shows a picker in place of
  the input (arrows, Enter, Esc, or type a value); the plain chat shows a numbered list. `wisp chat
  --json` gains `choice` and `choose` for it.
- Tab completes slash commands in `wisp-tui`: the command, `/config`'s words, settings and their values,
  models after `/model`, and views after `/inspect`; several matches show above the input and Tab
  cycles through them. `wisp chat --json` gains `complete` and `completions`.

Fixed:

- The chat status line shows the branch in a git worktree or a submodule, where `.git` is a file that
  points at the repository's own git directory; it showed none.

## 0.11.0

Added:

- `wisp chat --json` sends a `turn` line when a message goes to the model and when its reply is done,
  with the turn's number, time, and outcome, and every `event` line carries `text`, the line the
  terminal chat shows for it. `wisp-tui` shows the running turn and the last one's time in its status
  line, and words tool activity exactly as `wisp chat` does.
- `wisp-tui` asks for approval in a bordered dialog in place of the input: the command, the line it is
  part of, the directory, every reason, the pattern, and the keys, with the answer kept in the
  scrollback as one line.
- `wisp-tui` renders the Markdown in replies: headings, bullets, inline code, bold, and italics, with
  fenced code blocks kept as they are in the code colour.
- `wisp classifier train` trains a risk classifier on this Mac in well under a second, from the
  bundled examples or your own, and `wisp classifier measure` reports any classifier's accuracy and
  speed on labelled commands. A trained classifier answers in about 0.05 ms, against 1.3 to 2.3 s for
  the on-device model; use it with `approval.classifier: coreml`. The Core ML classifier now loads its
  model once instead of on every command, and reads contract 2 models.
- `wisp classifier train --from-audit` also learns from this Mac's audit log: the on-device model's
  verdicts on the commands you have run, secrets redacted, a refused command at least `moderate`.
- `triage` reads failures in the formats compilers and test runners print (Swift, clang, XCTest,
  rustc, swift-testing, cargo test, pytest, go test) exactly, and asks the model only about output those
  do not explain, so build and test output in a known format is triaged at once.
- MCP tools `dependency_audit` (npm, cargo, or pip audit JSON reduced to one line per advisory with its
  fix, most severe first), `flaky_tests` (two or more test runs, or one command run several times,
  compared for tests that pass and fail), and `hot_paths` (folded stacks reduced to self time and the
  heaviest paths). None uses a model.

Removed:

- `scripts/train-risk-classifier` and `docs/examples/risk-labels.csv`, which trained on the eval set;
  `wisp classifier train` replaces them.

Fixed:

- A message that asks for nothing, such as `test` or `hello`, gets a short question back. The
  on-device model used to take it as output to quote, sometimes running a command to produce it
  ("Test output: \"test\"."), and kept the pattern for the rest of the conversation.
- The rules rate deletion through `find … -delete`, `find … -exec rm`, and `xargs rm` as dangerous;
  they called it safe.
- The rules rate as dangerous reading common token files (`~/.config/gh/hosts.yml`, `.git-credentials`,
  `.npmrc`, `.pypirc`, the Docker and kube configs), copying or printing every file a search of the home
  folder or the disk matches (`find ~ … -exec cat`), and printing stored passwords with `security … -w`.
  The default classifier let the first through: the on-device model rated reading `gh`'s token safe.
- `wisp-tui` no longer redraws its band while idle, which could make the cursor flicker or restart its
  blink, and no longer resizes the band back and forth when deleting across a wrapped line.

## 0.10.3

Added:

- `wisp-tui`'s input grows with the message: a row for each line or wrapped line, up to six, scrolling
  within them beyond that, and shrinking back when the message is sent. Long lines now wrap instead of
  scrolling sideways.

Fixed:

- `wisp-tui` flickered when the input grew or shrank and as replies streamed in: each frame is now one
  synchronized update, and lines are added above the band by scrolling a region instead of redrawing it.

## 0.10.2

Added:

- `wisp-tui` line editing: a cursor moved with Left and Right, word motions (Alt or Ctrl with an arrow,
  Alt-B and Alt-F), Home and End, Ctrl-A, E, U, K, and W, Delete, Alt-Backspace, bracketed paste, and
  Alt-Enter for a newline. A long line scrolls to keep the cursor in sight.

## 0.10.1

Fixed:

- `wisp config` and the MCP resource `wisp://config` left out the `notifications`, `tools`, and
  `routing` settings; they now show every setting.

## 0.10.0

Added:

- Routing by input size: with `routing.ladder` in the config (such as `["system",
  "ollama:qwen3.8:27b"]`), `draft_change` and `wisp draft` pick the first model the measurements trust
  with a diff that large, and say which and why. Off unless configured; an explicit model wins.
- Custom tools: declare your own tools for the model in `~/.wisp/config.json` (`tools.custom`), each a
  command with `{placeholders}` and typed arguments, run through `run_command`'s policy, approval, and
  sandbox; `tools.disabled` leaves built-in tools out. See `docs/tools/custom.md`.
- `wisp draft [commit|pr|changelog]` and the MCP tool `draft_change`: a commit message, a pull request
  description, or a changelog line drafted from a diff (the staged one by default), with the subject kept
  under 72 characters and a `Why:` line left for the reason.
- `condense_log` reads this Mac's unified log with `last` (such as `10m`), optionally for one `process`
  or `subsystem`, in wisp's own process: `/usr/bin/log` refuses to run in any sandbox.

Changed:

- A session no longer re-judges a command line it has already classified: the model classifier's
  verdicts are kept per line and working directory (about 1.4 s saved each time). Approval is decided
  as before; a failed classification is retried.

Fixed:

- `system_info` asked about a named app ("Is Ollama running?") often left the name out and fell back
  to `ps`, which cannot run in the sandbox; the name is now a required argument.
- The condensing tools ignored a command's exit status, so a failing command's error message was
  condensed as though it were the output. They now return `exitStatus` and `timedOut` and start their
  text with a warning when the command failed.

## 0.9.0

Added:

- `wisp scan` and the MCP tool `scan_secrets`: find credentials, and with `--personal` personal data, in
  files, standard input, or a command's output, reported with masked previews. A diff is scanned by its
  added lines as `path:line`, so `git diff --cached | wisp scan` works as a pre-commit check; exits 1 on
  a finding.
- `wisp redact` and the MCP tool `redact`: text with credentials and personal data replaced by numbered
  markers such as `[REDACTED:email#1]`. `--thorough` adds the on-device model for names, addresses, and
  identifiers, over text the rules have already redacted.

- The MCP tool `condense_log`: a log (an app's log, CI output, `log show`) as its distinct messages,
  grouped by template and ranked by severity and count, or a macOS crash report as the process,
  exception, and faulting thread's frames. No model; a megabyte takes about a second.
- The MCP tool `json_shape`: the structure of a JSON or JSON Lines file without its data, with redacted
  string examples. No model.

- `wisp watch <command>`: reruns a command when files change (build output and `.git` ignored) or on
  an interval, triages a failing run with the model, and posts a notification when it starts or stops
  failing (`--notify change|failure|always|never`). The command is classified and approved once, when
  the watch starts, not on every run.

- The model tool `system_info`: listening ports, free space, folder sizes, your busiest processes,
  memory, one process, battery, macOS and hardware, and network, from fixed read-only probes wisp parses,
  so `wisp "what is using port 8080?"` gets a short, right answer.

Fixed:

- `summarise_diff`'s `secret` flag quoted the start of the added line, handing the credential to the
  caller; it now gives the kind and a masked preview.

## 0.8.3

Added:

- `/stats` in chat: timings of the session's recent model turns and classifier calls (count, failures,
  mean, P50, P95, maximum, prompt tokens where reported), then the latest calls. Kept in memory only, in a
  ring of the latest 256 calls.
- `/history` in chat lists the lines typed this session, and in `wisp-tui` Up and Down recall them, with
  what was being typed kept as a draft.

Changed:

- `/models` in chat is a table with a header, so the columns line up in the terminal and in `wisp-tui`;
  `wisp models` keeps its tab-separated lines for scripts.
- A model classifier's fallback verdict records `classifier.failure` in its `classifier.verdict` metadata.

## 0.8.2

Changed:

- `--model` help mentions `<backend>:<name>` spellings and points to `wisp models`, not only `system`
  and `private-cloud`.
- `docs/backends.md` records four Ollama models tried with wisp on 2026-09-23 (`qwen3-coder`,
  `granite4.1:8b`, `ornith:9b`, `qwen3.8:27b`): all drove the tools correctly, with timings.

## 0.8.1

Changed:

- `wisp models` and `/models` list only the models that can serve the conversation: they must resolve
  and, when the conversation has tools, declare tool calling. `--all` adds the excluded ones with the
  reason; `--no-tools` judges for a conversation without tools. An Ollama model that cannot hold a
  conversation, such as an embedding model, is refused by `--model` and `/model` with that reason
  instead of failing at the first prompt.

## 0.8.0

Added:

- Notifications: the model's new `notify` tool and `wisp notify <message>` show a macOS notification.
  Text is bounded, at most five a minute (`notifications.perMinute`), `notifications.enabled: false`
  turns them off, and every request is audited as `notification`.

## 0.7.0

Added:

- `/models` and `/model <name>` in chat: list the models this Mac can run and switch the conversation
  to one, keeping the transcript. Works in the plain chat and in `wisp-tui`.

Changed:

- The model introduces itself as Wisp.

## 0.6.1

Fixed:

- `wisp chat` launched through `PATH` did not find `wisp-tui`: it looked beside `argv[0]`, a bare name,
  rather than beside the process's real executable, so the plain chat started instead of the front end.

## 0.6.0

Added:

- `wisp chat --json`, a headless chat speaking JSON Lines, and `wisp-tui`, a Rust front end over it
  that keeps the conversation in the terminal's scrollback above a pinned input and status band. A
  merged from a one-day spike ([ADR 0029](docs/decisions/0029-tui-front-end.md)); the protocol may
  still change. The formula installs both binaries, and `wisp chat` on a terminal hands the session
  to `wisp-tui`; `--plain` keeps the line-based chat.

## 0.5.0

Fixed:

- An unanswered MCP approval now comes back at `approval.timeoutSeconds` as promised. The wait was
  decided at the deadline but not returned until the client eventually answered the dialog, which on
  2026-09-21 took 11 to 56 minutes for three refusals.

Changed:

- `wisp chat` shows its work: a status line above every prompt (model, directory, git branch and state,
  approval mode, context used), the model's tool calls and results live as one dim line each, a compact
  approval dialog with a one-line key, colour on a terminal (off when piped or with `NO_COLOR`), and
  new commands `/inspect`, `/status`, `/last`, plus `--yes`. Replies alone go to stdout, as before.

## 0.4.0

Renamed: daimon is now **wisp**. The binary is `wisp`, the home directory `~/.wisp` (`WISP_HOME`), the
environment variables `WISP_*`, the unified-logging subsystem `com.pidster.wisp`, the MCP server `wisp`
with `wisp://` resources, and a new formula in the Homebrew tap (`brew install pidster/tap/wisp`).
Nothing carries over automatically: move `~/.daimon` to `~/.wisp` yourself if you want your approvals and
transcripts, and `brew uninstall daimon`. The `daimon` formula stays in the tap.

Added:

- `summarise_diff`, a new MCP tool: run a command that prints a diff (or read a diff file) and get back
  a headline, one line per file with its change kind and line counts, and flags for secrets, deleted or
  disabled tests, and binary or generated content. Paths and counts come from the diff itself; the diff
  never leaves the Mac.
- Measurements: `scripts/check eval` records what each delegated task achieved (`triage`,
  `edit_file` replace after read, schema-shaped replies, the risk classifier) into a resource embedded
  in the binary; `wisp tools --markdown`, `wisp://tools`, and the new `wisp://measurements`
  resource publish them so a caller knows what to trust.

Changed:

- Approvals for programs whose first word is the verb (`git`, `cargo`, `swift`, `npm`, `brew`, `docker`
  and others listed in `multiplexers.txt`) are remembered by verb: `git commit *` and `git push *` are
  separate, so a session answer for one no longer covers the other. A standing approval stored under
  the old `git *` still counts until it expires.
- `edit_file` replace takes `line`, the number `read_file` showed, with `content` as the whole new line
  and `find` as an optional check on that line; a drifted number changes nothing. The by-`find` form
  measured 3 of 5, because the model retyped the neighbouring line into `content`.
- Local runtimes that truncate silently no longer lose the instructions: `Agent` condenses the transcript
  ahead of the window when the usage the last reply reported, plus the new prompt, would pass 85% of it,
  audited as `context.condensation` with reason `budget`. Ollama is asked for an explicit window on every
  request (`ollama.contextLength`, default 8192, sent as `num_ctx`), and `/tokens` shows the reported
  usage for models that cannot count.

## 0.3.0

Added:

- `edit_file`, a new model tool: write a whole text file, append to it, or replace one exact
  occurrence of a piece of text. Writes are atomic and confined to the directories the sandbox lets
  commands write under, every edit passes the risk classifier and approval as `edit_file <mode> <path>`, and
  each edit is audited as `file.write` and listed in the receipt's `files`.
- `triage`, a new MCP tool: run a build or test command on this Mac (or read an output file) and get
  back only the failures as `kind`, `location`, `message`, judged chunk by chunk by the on-device model.
  The raw output never leaves the Mac; the command runs under the same policy, sandbox, and approval
  as the model's own `run_command`.
- Structured output: `respond` takes a `schema` (a JSON Schema object in an accepted subset) and
  returns JSON of that shape, parsed into `structuredContent.output`; the CLI takes `--schema <path>`.
  A model that does not declare guided generation is refused before generation.
- `respond` results carry a `receipt`: the turn's tool calls with arguments and result sizes, commands
  with exit status, policy denials, approval decisions, and errors, folded from the thread's audit
  events so a calling harness can verify delegated work without reading the log.

Fixed:

- `--model private-cloud` failed after the request with an opaque `ModelManagerError` 1046. Private
  Cloud Compute needs the managed `com.apple.developer.private-cloud-compute` entitlement, which an
  ad-hoc signed command-line tool cannot carry; wisp now checks its own signature and refuses the
  model with a sentence before anything is sent. `wisp models` shows the same reason.

## 0.2.0

Added:

- Model backends are a registry: `--model <backend>:<name>` names a local runtime by scheme, `wisp
  models` lists every backend's models with their declared capabilities, and a backend this build lacks
  is a clear error. Ollama now reports each model's real capabilities from its `/api/show`, so an
  embedding model is refused for tool use before generation rather than failing during it.
- `--no-tools` on the CLI and `tools: []` over MCP open a text-only conversation, which any model can
  run; a request that needs tool calling on a model that does not declare it is refused with a hint.
- The audit log records `model.resolved` when a conversation opens: backend, model, asset, declared
  capabilities and who declared them, and the tools in use.
- Core AI: `--model coreai:<bundle>` runs a model exported to Apple's Core AI format, in wisp's own
  process, through the bridge from `apple/coreai-models`. Bundles live under `<home>/models/coreai`
  (`config.json` `coreai.modelsDirectory`) or are named by path; `wisp models` lists them with kind,
  compression, source, and size; a missing bundle is refused with where wisp looked and the export
  command. Capabilities come from the bundle. See `docs/backends.md`.

- `inspect`, a read-only tool the model can call to see wisp's effective config, this conversation's
  status, the standing approvals, or recent audit events, bounded to 4 KiB.
- MCP resources `wisp://config`, `wisp://status`, `wisp://approvals`, `wisp://audit`, and the
  template `wisp://audit/{session}` for one thread's events, so a calling harness can read wisp's
  state without a model turn.
- `wisp config` prints the effective configuration as JSON.

- MLX Swift: `--model mlx:<directory>` runs a model in MLX or Hugging Face safetensors layout in
  wisp's process through `mlx-swift-lm`'s bridge, in builds made with `--traits MLX` (the release
  is); a build without the trait refuses `mlx:` models with the reason. Capabilities are declared by the
  operator per model in `config.json`'s `mlx.models`; an undeclared model is text only. Verified with
  `mlx-community/Qwen3-1.7B-4bit`: text replies in 2.5 s including load, and the tool loop 3 of 3 with
  `toolCalling` declared. The Homebrew release does not include MLX, because it needs a Metal library
  bundle beside the binary; build with `--traits MLX` yourself. See `docs/backends.md`.
- `approval.classifier` chooses what judges commands beside the rules: `rules`, `system-model` (the
  default, unchanged), or `coreml`, a Core ML text classifier you train from a `text,label` CSV with
  `scripts/train-risk-classifier`. The model must follow a versioned contract or it is rejected; every
  failure or low-confidence verdict is `moderate` with the reason; the audit records the model's
  identity, version, label, and confidence. Measured on 2026-09-20: a model trained on the 45-command
  eval set scores 45/45 on it (its own training data, so no evidence of judgement); trained on the 35
  non-held-out commands it got 5 of the 10 held-out ones right, and two dangerous commands it called
  `safe` were kept off `safe` only by the confidence guard. Not fit to judge alone; measure your own
  with `WISP_COREML_MODEL=<path> scripts/check eval` before relying on it.

Changed:

- The `run_command` sandbox also allows writes under the per-user cache directory
  (`getconf DARWIN_USER_CACHE_DIR`), where Clang keeps its module cache; a build that compiles a C
  module inside the sandbox (SwiftPM compiling a dependency's manifest, say) used to fail with "could
  not build Objective-C module 'Darwin'".
- `wisp` with no prompt on a terminal prints its help instead of waiting silently for stdin; a piped
  stdin is still read.

## 0.1.5

Fixed:

- Codex could not connect: its `initialize` carries `capabilities.experimental` with object values,
  which the MCP specification allows, and the Swift SDK rejected the whole request with `-32603`. wisp
  now normalises such messages before the SDK decodes them. wisp never reads the field; no client
  feature is enabled by it. The captured request is a regression test.

## 0.1.4

Added:

- Three-layer instructions: wisp's own system prompt (a text file in the source tree, embedded at build
  time), the operator's `systemPromptExtension` in `config.json`, and the caller's `--instructions` or MCP
  `instructions`, rendered in that order. A caller can no longer replace wisp's framing. The old config
  key `instructions` is still read as the extension.
- The audit `session.start` event records the extension and the caller's instructions separately.
- `wisp mcp --tool` selects the tools threads get unless a `respond` call names its own.

Changed:

- Releases run the full test suite and a coverage gate; line coverage must not fall below the recorded
  baseline.
- `--resume` of a missing or invalid transcript name is a usage error (exit 64), like other bad inputs.

## 0.1.3

Added:

- Run sessions on a local Ollama model with `--model ollama:<name>`, in `config.json`, or per MCP thread.
  `wisp models` lists Apple's two models with availability and every model Ollama serves. New `ollama`
  config section for the server address and per-request timeout; `wisp doctor` checks the configured
  model resolves.
- Approvals have four scopes: this turn, this session, this project (30 days, this directory), always
  (30 days). Project and always approvals persist under `~/.wisp/approvals.json`; `wisp approvals`
  lists, revokes, and clears them. Dangerous commands are never persisted.
- Each simple command in a line (`a && b | c`) is checked and approved on its own and remembered by its
  program, so `head -n 5 x` is remembered as `head *`.
- A once-approval covers the rest of the turn, however many commands the model runs.
- The MCP `respond` result reports `refusals`: commands the gate refused this turn, with reasons.
- A bare `exit`, `quit`, or `q` ends `wisp chat`.

Changed:

- The approval threshold is `safe`, `moderate`, `dangerous`, or `never`; the on-device classifier runs
  only when the rules did not decide.
- Every face of wisp (`respond`, `chat`, `mcp`) shares one set-up path and one approval store, so a
  "this project" answer given over MCP is written once and honoured everywhere.

Fixed:

- "This project" approvals given over MCP were not being persisted.
- Partial `commandPolicy` objects in `config.json` keep every other default.

## 0.1.2 and earlier

See the GitHub releases for 0.1.0 to 0.1.2: the first Homebrew releases, with the sandboxed
`run_command`, `read_file`, `current_date`, the audit log, the risk classifier and approval gate, the MCP
server with per-thread conversations, and model selection between `system` and `private-cloud`.
