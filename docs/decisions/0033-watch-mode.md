# ADR 0033: Watch mode reruns a command on file changes and notifies when its outcome turns

Date: 2026-09-23. Status: accepted. Builds on [ADR 0023](0023-condensing-tools.md) and
[ADR 0030](0030-notifications.md). Amended 2026-10-02: a file-triggered run waits for changes to settle
("Amendment", at the end).

## Context

An on-device agent costs nothing to keep running, which a remote model cannot match: it can watch a
build or test loop and speak up only when something changes. `triage` already turns failing output into
a short list, and `Notifier` already posts bounded, rate-limited, audited notifications. What was
missing was the loop that ties them to the file system and to time.

## Decision

- **`wisp watch <command>`** runs the command at once, then again on each change under the watched
  paths (FSEvents through `FileWatcher`, 0.5 s latency so a save of several files is one change) and,
  with `--every`, on an interval. Changes under build output and version control (`.git`, `.build`,
  `target`, `node_modules`, `DerivedData`, and the like) and editor scratch files are ignored, since the
  command writes there itself and would otherwise set itself off forever. Triggers are buffered one
  deep: changes during a run cause one rerun after it, not one per change.
- **The command runs through `CommandRunner`** on a conversation `watch-<id>`, under the policy,
  sandbox, classifier, and approval as every command does, with the terminal approver (or `--yes`).
  Choosing "session" on the first approval covers the reruns.
- **Notifications follow a policy**: `change` (default: when pass turns to fail or back, and on a
  first run that fails), `failure`, `always`, `never`. The body says whether it is failing and gives the
  first finding; the subtitle is the command; a failure plays the sound. Posted through `Notifier` with
  source `watch`, so the rate limit and the off switch apply.
- **A failing run is triaged** by the model into findings (`Triage`) when it is new or will be
  notified; a failure that repeats unannounced is not triaged again, so a broken build left alone costs
  no model turns. `--no-triage` turns it off; a triage error is reported and does not end the watch.
- **`Watcher` holds the loop in `WispCore`**, free of time and the file system: triggers arrive on an
  `AsyncStream`, and running, triaging, notifying, and reporting are closures, so tests drive it with a
  scripted stream. `FileWatcher` owns the FSEvents stream and is not `Sendable`; only its sink crosses
  threads.
- **Audit**: each run is a `watch.run` event with the trigger, exit status, state, whether it turned,
  the finding count, and whether it notified. Ctrl-C stops after the current run so the session ends
  cleanly; a second Ctrl-C exits at once.
- CLI only: a long-running loop is not an MCP tool call.

## Consequences

- Smoke-tested on 2026-09-23 with `ls ok 2>&1` in a scratch directory: failed at start, passed on the
  change that created the file, ignored a write under `.build`, and failed again when the file was
  removed, each failure triaged by the system model. Every run took 1.3 to 1.7 s for a command that
  itself takes milliseconds: the risk classifier judges the command on each run, as it does for every
  command. Caching its verdict for an unchanged command line is a possible later saving.
- A watch of a large tree relies on the ignore list; a project whose output lands elsewhere should watch
  its source directories with `--path`.
- Tests without the model or real time: the policy matrix, the messages, the loop over scripted triggers
  (notifying, triaging only new failures, the run cap, timeouts, triage errors, a refused command), the
  ignore rules, and one real FSEvents change in a temporary directory.

## Amendment, 2026-09-23: approve once, not per run

The first version cleared the command through the approval gate on every run, so each run paid the
model classifier (1.3 to 1.7 s for a command that takes milliseconds) and, for a risky command, could ask
again. The command line of a watch never changes, so its verdict cannot either. `CommandRunner.authorize`
now checks the policy and clears the gate once, before the first run, and returns an `Authorized` value
that runs only that exact line in that directory without the gate. Every run still checks the policy,
runs under the sandbox, and records `policy.decision` and `command.outcome`; approving the watch once, at
any scope, covers its reruns. Measured the same day: runs of `ls 2>&1 | wc -l` fell from 1.3 s to under
0.1 s each, and the classifier ran once for four runs (`CommandRunnerPolicyTests` asserts one
classification for three runs).

## Amendment, 2026-10-02: settle before a run

Amended 2026-10-02: a run triggered by file changes starts only once no change has arrived for the settle
period, `--settle <seconds>` or `watch.settle` in `config.json`, 1 s by default and 0 to turn it off. FSEvents
gathers changes over a fixed 0.5 s, so a long burst (a checkout, a formatter, save-all) could start a run
part-way through it, which failed and then passed once the burst ended. The debounce is a trailing one,
`TriggerSettler`, where the triggers are produced: it takes a `Clock` (a scripted one in tests,
`ContinuousClock` in `wisp watch`) and turns a burst of changes into one `.change`. `Watcher` stays free of
time. The first run and `--every` runs are not delayed; changes during a run still collapse into one pending
run through the stream's buffer of one.
