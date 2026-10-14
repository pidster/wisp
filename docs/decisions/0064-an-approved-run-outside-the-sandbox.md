# ADR 0064: An approved run outside the sandbox

Date: 2026-10-14. Status: accepted; built 2026-10-14. Chosen by the operator on 2026-10-14. Amends
[ADR 0009](0009-command-policy-and-sandbox.md) (every model's command runs under the sandbox when it is on) and
[ADR 0054](0054-the-sandboxs-refusals-checked.md) (the refusal note).

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
    custom tools, `system_info`, or `triage`; only `run_command` asks.
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
