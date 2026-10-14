# ADR 0064: An approved run outside the sandbox

Date: 2026-10-14. Status: accepted; built 2026-10-14. Chosen by the operator on 2026-10-14. Amends
[ADR 0009](0009-command-policy-and-sandbox.md) (every model's command runs under the sandbox when it is on) and
[ADR 0054](0054-the-sandboxs-refusals-checked.md) (the refusal note). Amended 2026-10-14 (below): the person runs a
command outside the sandbox themselves by typing it after `!!`, which amends
[ADR 0049](0049-commands-typed-in-chat.md) and changes item 10.

## Context

wisp's Seatbelt profile (`CommandPolicy.seatbeltProfile`) lets a command write only under its writable roots: the
launch directory, the temporary directories, the per-user cache directory, `~/Library/Caches`, `~/.cargo/registry`,
and `~/.cargo/git`. Probed on this Mac on 2026-10-14:

| Command | Writes | Under the sandbox |
| --- | --- | --- |
| `cargo update` in the project | the project's `Cargo.lock`, the registry cache | works |
| `cargo install …` | `~/.cargo/bin`, `~/.cargo/.crates.toml`, `~/.cargo/.crates2.json` | refused |
| `rustup update` | `~/.rustup` | refused |
| any Homebrew write | `/opt/homebrew/…`, `~/Library/Logs/Homebrew` | refused; `brew upgrade --dry-run` stops with Homebrew's "You should change the ownership of these directories" |

Widening the writable paths cannot fix Homebrew. Homebrew 7 runs its own `sandbox-exec` for fetching, processing
downloads, `post_install`, and source builds (`/opt/homebrew/Library/Homebrew/sandbox.rb`, `formula_installer.rb`).
Seatbelt refuses a nested profile that differs from the outer one (ADR 0009), Homebrew's own code says a nested
sandbox hangs on macOS, and its opt-out, `HOMEBREW_AVOID_NESTED_SANDBOXING`, is refused for the default `/opt/homebrew`
prefix. So no Seatbelt profile wisp could apply, however wide, lets `brew upgrade` run. Widening by default would also
make `~/.cargo/bin` and `/opt/homebrew/bin`, both on `PATH`, writable to every command the model runs: a binary
planted there runs the next time the person types its name.

Considered:

| Option | What it does | Why not, or why |
| --- | --- | --- |
| (a) Widen the default writable paths | `~/.cargo`, `~/.rustup`, `/opt/homebrew` writable to every command | Homebrew still fails (its nested sandbox), and every command could write programs on `PATH` |
| (b) Leave it to the operator's `writablePaths` | The operator widens the set by hand | The same for Cargo and rustup; Homebrew still fails |
| (c) Hand it back | The model tells the person to run the command themselves | What happens now; the chore is not done |
| (d) An approved run outside the sandbox | The model asks; the person approves that exact line, that once; it runs without `sandbox-exec` | Chosen by the operator on 2026-10-14 |

## Decision

1. **One argument.** `run_command` takes an optional `outsideSandbox`, guided as "Set true only for a command the
   sandbox refuses, such as brew upgrade or cargo install; the person must approve it." The tool's description is
   unchanged; its `limits` text says what asking does here.
2. **The lists first.** The policy's deny and allow patterns apply exactly as to any command, so `sudo`, a pipe into
   a shell, and `wisp approvals approve` are still refused outright.
3. **The operator's switch.** `commandPolicy.sandbox.allowOutsideSandbox`, true by default, settable with
   `wisp config set` (the command policy's one setting there; the rest of it is still edited by hand). False refuses
   every request with the sandbox on, after the lists: `error: command denied by policy: running outside the sandbox
   is turned off here (commandPolicy.sandbox.allowOutsideSandbox is false); …`. No tool changes it. It sits in
   `sandbox` beside `allowNetwork` and is named after the argument it governs.
4. **The person, always.** The line is put to the person as one request of its own kind
   (`ApprovalRequest.Kind.outsideSandbox`): the whole line, remembered by nothing, at `moderate` at least (the
   highest of its parts' verdicts and the rules' verdict on the whole line, if higher), with
   `runs OUTSIDE the sandbox: it may write anywhere you can, ~/.wisp included; this one run only` first among the
   reasons. It is asked whatever the classifier and `approval.threshold` say, `never` and a command on the read-only
   list included. Nothing held covers it: not a once-approval earlier in the turn, a session approval, or a `project`
   or `always` entry in `approvals.json`; and the answer covers nothing after it, not the same line a second later.
   Every part is still classified and its verdict audited.
5. **"This session" is once.** Where a face draws the choices, it offers only once or no: the terminal's `[y]once
   [n]o` with "never remembered"; the MCP dialog has no scope picker; `wisp-tui` takes `y` and `n` alone. Where the
   answer comes as a word the face cannot narrow (`wisp approvals approve ID --scope session`, `/approvals approve ID
   always`, a client that sends a scope anyway), the gate takes it as once, records what was asked as
   `approval.decided`'s `downgradedFrom`, and `wisp approvals approve` says so: `approved once, outside the sandbox
   (session is taken as once): …`. This is how [ADR 0059](0059-one-set-of-model-actions.md) treats a model pull, and
   it needs no change to the pending channel's decisions, whose words stay the same for every command.
6. **No one to ask, no run.** A channel that asks no person (`Approver.asksAPerson` false: `--yes`'s
   `AutoApprover`, non-interactive `respond`'s `DenyingApprover`) cannot answer it, and the gate refuses it without
   asking: `error: command not approved: running outside the sandbox is asked of a person every time, and no one can
   be asked here (--yes does not answer it); run it without outsideSandbox, or ask the person to run it themselves`.
   Under `wisp mcp` with `approval.outOfBand` off and a client without elicitation, the refusal says the client cannot
   ask. A runner with no gate at all refuses it too. With `approval.outOfBand` on, it is filed and waits as any
   request does, so the person can answer from a terminal or `wisp-tui`.
7. **Every face says so.** The terminal dialog opens `⚠ approve OUTSIDE the sandbox`; the MCP dialog's title is
   `wisp: run OUTSIDE the sandbox? (<level> risk)` and its message opens `Command to run OUTSIDE the sandbox, this
   once:`; the pending file carries `outsideSandbox: true`, bound into the request's SHA-256 so a file edited to drop
   it is refused when answered; the banner's title is `wisp: approve OUTSIDE the sandbox`; `wisp approvals pending`
   on a terminal prefixes the command with `OUTSIDE THE SANDBOX:` (piped, the column stays the command, for a
   script); plain chat's note reads `run <line> OUTSIDE THE SANDBOX, this once, in …`; the `approval` line of `wisp
   chat --json` carries `outsideSandbox: true`, and `wisp-tui` titles its dialog `approve OUTSIDE the sandbox`, adds
   the line `runs OUTSIDE the sandbox: it may write anywhere you can` in the dangerous colour, and says "never
   remembered: this run only".
8. **Approved, it runs without `sandbox-exec`**, with the same shell, process group, time limit, output bound, and
   output store as any command, and the result ends `sandbox: ran outside the sandbox, as the person approved, this
   once`.
9. **When it changes nothing, it says so.** With the sandbox off (`sandbox.enabled` false, or `--unsafe`) every
   command already runs without it: the request is cleared as any command is, nothing more is asked, and the result
   ends `sandbox: outsideSandbox changed nothing: the sandbox is off here`. When wisp itself runs inside another
   sandbox (`CommandRunner.isNestedSandbox`), its commands already run plainly under that one, which wisp cannot
   leave: the request is cleared as any command is and the result ends `sandbox: outsideSandbox changed nothing:
   wisp runs inside another sandbox, which confined this command`; `limits` says so too. The switch is checked
   before nesting, so off refuses in both.
10. **A command the person types after `!` is unaffected**: it never carries the argument. Nor do `wisp watch`,
    custom tools, `system_info`, or `triage`; only `run_command` asks. Changed by the amendment of 2026-10-14
    (below): a command the person types after `!!` runs outside the sandbox, through the same resolution, with no
    one asked.
11. **Audited.** `policy.decision` carries `outsideSandbox: true` where the request applied (and `sandbox: false`
    when allowed), or `outsideSandboxIgnored` (`sandbox-off` or `nested`) where it changed nothing;
    `approval.requested`, `approval.decided`, and `approval.pending` carry `outsideSandbox: true`; `command.outcome`
    carries `outsideSandbox: true` for a command that ran without the sandbox.
12. **The refusal note offers it.** When ADR 0054's check finds the sandbox refused a model's command, or may have
    (`refused` or `guess`, not `not-the-sandbox`), and the switch is on, the note ends `; if it must, ask again with
    outsideSandbox true (the person approves each run)`.

### wisp's home, unsandboxed

The profile's denial of writes under wisp's home (`~/.wisp`, or `WISP_HOME`) is what keeps a command from changing
wisp's approvals, facts, configuration, and pending answers. A command run outside the sandbox has no profile, so
that protection is gone for it: it could write `approvals.json`, `config.json` (`approval.threshold never`, say), or
an answer file in `pending/` for another request, whose binding any process running as the person can compute.

No clean mitigation exists within this design. Any Seatbelt profile, even `(allow default)` with one `deny` for the
home, is a sandbox, and Homebrew's own nested `sandbox-exec` is refused under it, which is the failure this change
exists to get past. Checking the home before and after the run would detect a change, not prevent it, and an answer
already taken by a server is not undone by noticing it. Neither is built.

It is accepted because of what the person approves. The request is the person's alone: the asking agent cannot
answer it, by any channel ([ADR 0046](0046-approval-and-notifications-over-mcp.md)'s rule holds for this request as
for every other: nothing in MCP approves, `--yes` does not, and the model cannot write the answer from inside the
sandbox). It is for that exact line, in that directory, once, shown marked as outside the sandbox with a reason that
names `~/.wisp`. What the person grants is what they grant when they type the line in their own terminal: their
own privileges, for that command. A line that runs a script (`./x.sh`) does whatever the script does, unsandboxed;
the person reads the line before approving it, and the request asks every time, so approving one run says nothing
about the next.

## Consequences

- The model can do the chores the sandbox refused (`brew upgrade`, `cargo install`, `rustup update`), each one asked
  of the person and announced as outside the sandbox on every face.
- Every such request asks, even for `ls`, and nothing remembers it: the noise is the point.
- An operator who never wants it sets `commandPolicy.sandbox.allowOutsideSandbox false`.
- Under `--yes` and in non-interactive `respond`, the model is told why it cannot, and can hand the command back.
- `Approver` gains `asksAPerson`, true by default, false for `AutoApprover` and `DenyingApprover`. `CommandRunner.run`
  gains `outsideSandbox`, and `CommandRunner.OutsideSandbox` says what a request comes to.
- Not probed: `brew upgrade`, `cargo install`, and `rustup update` were not run through `outsideSandbox`, by the rule
  against changing the machine's installed software while building this; the mechanism is tested with a harmless
  write to a scratch directory outside the writable roots. The MCP dialog without a scope field is to the
  specification (an empty `properties`), but Claude Code's rendering of it is not yet probed.
- Tests without a model (`OutsideSandboxTests`, `ElicitationApproverTests`, `RespondOutsideSandboxTests`, and
  `wisp-tui`'s): what a request comes to under each setting; a read-only command asked at every threshold, `never`
  included; the whole line asked once at its highest level; a session or always answer taken as once and covering
  nothing after; no once, session, or stored approval covering it; `--yes` and a denying channel refusing it with the
  reason; denial and silence; every face's text; the pending mark bound; the out-of-band path with an `always` answer;
  the deny list; the switch off; no gate; the sandbox off; the `limits` text and the schema; a typed command; and,
  with the real sandbox (skipped when nested), a write outside the roots refused sandboxed with the hint in the note,
  refused when declined, and made when approved and run outside, and a write to a protected directory, standing for
  `~/.wisp`, refused sandboxed and made outside. Over MCP: a `respond` whose model asks with no way to ask the person
  is refused with the reason, and nothing runs.

## Amended 2026-10-14: the person's own run outside the sandbox

The operator asked, on 2026-10-14, for the person to be able to do in chat what the model now asks to do: run one
command outside the sandbox themselves, as they would in another terminal, without leaving wisp. A typed command
([ADR 0049](0049-commands-typed-in-chat.md)) already drops the checks that stand in for the person (the classifier,
the approval, the time limit) and keeps the ones that protect the Mac (the lists, the sandbox); this lets the person
drop the sandbox too, for one line, by saying so as they type it.

1. **The line is `!!command`.** In the plain chat, and over `wisp chat --json`, a line that starts with `!!`, the two
   marks together, is a command the person runs outside the sandbox; what follows, trimmed, is the command (`!!brew
   upgrade` and `!! brew upgrade` alike). `ChatInput.command` gains `outsideSandbox`. Only the marks together count:
   `! !x`, with a space, is an ordinary command whose text is `!x` (chosen as the simplest rule that leaves a way to
   run a command that starts with `!` in the sandbox), and `!!!x` runs `!x` outside. `!!` alone runs nothing, as `!`
   alone does. `!!` is not the shell's history: `sh -c` keeps none, and no wisp face offers one.
2. **Typing it is the approval.** It runs through `Agent.runTyped` and `CommandRunner.run` with `origin` `.person` and
   `outsideSandbox` true: the same resolution as item 9 (`OutsideSandbox.resolve`, now for either origin), the policy's
   deny and allow lists first, then the operator's switch, then no gate at all: no classifier, no question, no
   approval held or asked. It keeps a typed command's terms: the output bound, the output store, no time limit, and
   Ctrl-C stopping it. Item 10's "unaffected" is reversed for `!!` deliberately; `run`'s doc comment says so.
3. **The switch holds.** `commandPolicy.sandbox.allowOutsideSandbox` false refuses it after the lists, with the
   person's wording: `running outside the sandbox is turned off here (commandPolicy.sandbox.allowOutsideSandbox is
   false); type it after a single ! to run it in the sandbox`, shown as `· blocked by policy: …`.
4. **When it changes nothing, it says so.** With the sandbox off or wisp nested, the command runs as a `!` command does,
   and chat says `· !! changes nothing here: the sandbox is off, so every command runs without it` or `… wisp runs
   inside another sandbox, which confines this command`.
5. **Every face marks it before it runs.** Chat renders the person's allowed `policy.decision` with `outsideSandbox`
   as `! running OUTSIDE the sandbox, as you typed it: it may write anywhere you can`, in the danger colour, before
   the command starts; the activity reads `running … outside the sandbox`; the plain chat colours the line's prompt
   marker in a new palette colour, `outside`; `/help` lists `!!COMMAND`.
6. **`wisp-tui` gains outside mode,** a third state of the input box beside command mode (`InputMode`: normal,
   command, outside). `!` typed with the cursor at the start in command mode enters it; there `!` at the start is
   text. Backspace at the start of the line, or Delete in an empty box, steps back one mode: outside to command mode
   (amber), then to the normal prompt, keeping the text. A paste at the start steps up a mode for each `!` it starts
   with, as typing them would (`!!x` into an empty box, `!x` at the start in command mode). The box turns `outside`,
   **#D27068**, a muted red darker and greyer than `ember` and `removed` (#FF6B6B), with command mode's black text,
   and its marker is `!!`; the sent line is `!! command` on `outsideSent`, **#693834**, half its brightness as
   `commandSent` is of `command`. Both are defined in both palettes and checked by the gate's palette check. They are
   a first proposal, not chosen from renders as command mode's were; the operator may pick others. Recall brings a
   line back in the mode it was sent from. Two cases keep the box honest: text in the normal box that starts with
   `!!` (pasted after a space) is not sent unseen, but put into outside mode for a second Enter; and command mode text
   that starts with `!` is sent as `! !x`, so it runs in the sandbox as the amber box showed.
7. **Audited and told.** `policy.decision` and `command.outcome` carry `origin: "person"` and `outsideSandbox: true`
   (item 11's fields); `command.typed` carries `outsideSandbox: true` for every `!!` line, and its summary marks it
   `!!`. The thread record's `PersonCommand` gains `outsideSandbox` (written only when true, so older records read),
   and the model's notice says the person ran it `themselves, outside the sandbox,`.

The home's exposure is the section above's, accepted on the same ground, more plainly: the person typed the line.
Tests without a model (`PersonOutsideSandboxTests`, and `wisp-tui`'s): the parsing (`!!x`, `!!`, `! !x`, `!x`,
`!!!x`); nobody asked and, with the real sandbox (skipped when nested), a write outside the writable roots refused
after `!` and made after `!!`; the switch off; the deny list; the sandbox off; the audit fields and summary; the
record's round trip and notice; chat's lines, the marker's colour, and a bare `!!`; and in `wisp-tui` every
transition, each paste, the line sent, recall, the round trip of a line and its mode, and the colours.
