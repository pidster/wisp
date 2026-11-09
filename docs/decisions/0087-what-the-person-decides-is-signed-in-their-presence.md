# ADR 0087: What the person decides is signed in their presence

Date: 2026-11-08. Status: proposed; decision 3 settled by the operator on 2026-11-09, the rest not yet agreed;
probes first (below). Would amend
[ADR 0046](0046-approval-and-notifications-over-mcp.md) (the terminal-only answers),
[ADR 0048](0048-permanent-facts-over-mcp.md), [ADR 0062](0062-the-inquiry-verb.md), and
[ADR 0085](0085-an-approval-lasts-a-time-in-its-project.md) (a remembered approval), and settle what
[ADR 0072](0072-a-dmg-and-a-declared-layout.md), decision 5, left open (where the home belongs).

## Context

Raised by the operator on 2026-10-23 and planned in [roadmap.md](../roadmap.md), "Later: protecting wisp's state from
other agents": wisp, being on the device, may be trusted with what other agents are not, so what keeps them out?

macOS separates processes by user, not by program. Any agent with a shell running as the person (Claude Code, Codex,
a script) can do what follows today, read from the code on 2026-11-08:

- **Answer for the person.** A request waiting in `~/.wisp/pending` carries `binding`, a SHA-256 over the fields the
  person is shown (`PendingApprovals`). It stops an answer being moved onto another command, but it is not keyed: any
  process that reads the request can compute it and write `<id>.answer.json`, which the server accepts. `wisp
  approvals approve`, `wisp facts keep`, and `wisp questions answer` refuse to run without a terminal, which ADR 0046
  calls "a speed bump, not a wall: a process can obtain a pseudo-terminal". ADR 0046 named the next step if it proved
  too weak: an answer token given only in the notification.
- **Change the policy.** `config.json` holds `commandPolicy` (the deny and allow patterns,
  `sandbox.allowOutsideSandbox`) and `approval` (the threshold, the classifier); a process can write it.
- **Grant itself approvals.** `approvals.json` holds the remembered `project` approvals; an entry written there
  covers every later run of its pattern for 30 days.
- **Admit permanent facts**, which only the person admits (ADR 0048), by writing `facts.json`.
- **Read everything wisp keeps**: threads, the audit log with commands' output verbatim, facts, the output store,
  directly or by running `wisp`.

Every file is the person's alone (mode 0600, directories 0700), which keeps other users out and no program of the
person's. wisp's own model is already kept out: the sandbox refuses its commands' writes under `~/.wisp`, and the
default policy refuses it `wisp approvals`, `wisp facts`, and `wisp questions` (ADR 0046).

What wisp cannot change, and this ADR says plainly: an agent with an unsandboxed shell can run any command the
person can, without wisp. wisp is not its sandbox. What wisp can protect is narrower, and matters more as wisp keeps
more:

1. **That a decision wisp records as the person's was the person's.** The audit's `approval.decided`, a fact kept as
   permanent, and an answer to the model's question are evidence; a forged one is a false record of consent.
2. **That what wisp acts on later, unattended, was set by the person.** A remembered approval runs commands without
   asking, and the tasks of [ADR 0078](0078-tasks-a-plan-and-its-grant.md) would run scheduled work under a stored
   grant. Forging either outlives the agent that did it, and lends it the person's authority later. This is why the
   roadmap holds stored grants until this work is done.

Options considered, for the answers:

1. **An answer token in the notification only**, ADR 0046's next step. Rejected: the banner's text reaches
   `Wisp Notifier.app` as its command line (`--body`), which any process running as the person can list with `ps`,
   and a token proves only that something read it, not that the person did.
2. **A keyed binding**, an HMAC whose key is in the keychain for wisp alone. Rejected on its own: any process can run
   `wisp approvals approve` under a pseudo-terminal, and wisp would sign for it.
3. **The person's presence**, by Touch ID or the login password through LocalAuthentication, with a signature only the
   person's presence releases. An agent can start the prompt, but cannot answer it.

macOS offers a Developer ID tool, signed with the hardened runtime since 0.30.1 and with no entitlements:
LocalAuthentication; keys in the Secure Enclave (CryptoKit's `SecureEnclave.P256`), whose use can require the
person's presence; and keychain items whose access names the program allowed to read them. Whether each works for a
command-line tool as wisp is signed is the first thing to probe.

## Decision

Proposed; each point is the operator's to agree, change, or reject.

1. **One key, in the Secure Enclave, used only with the person present.** wisp makes a P-256 signing key in the Secure
   Enclave the first time it needs one, with access control that requires the person's presence (Touch ID or the
   password) for each signature. The private key never leaves the Enclave. Its reference and its public key are kept in
   a keychain item whose access names wisp's signature (the Developer ID team), so another program cannot replace the
   public key without the person agreeing to a keychain prompt. Checking a signature needs only the public key and asks
   no one, so a server that waits for an answer checks it unattended.
2. **An answer that grants is signed in the person's presence.** An approval, a fact kept as permanent, and an answer
   to the model's question, given anywhere but the dialog of the face that asked (`wisp approvals approve`,
   `wisp facts keep`, `wisp questions answer`, `wisp-tui`'s dialog for another face's request, chat's
   `/approvals approve`), are signed: the process answering asks for the person's presence, with a prompt naming what is
   granted (the command and its directory, the fact, or the question), and puts the signature over the binding in the
   answer. The waiting server refuses an answer without a valid signature and audits the refusal. Refusals (`deny`,
   `drop`, `decline`) are not signed: a forged refusal fails safe, as silence does. The terminal check stays, now beside
   a wall rather than in place of one.
3. **The asking face's own dialog is left as it is.** `y` at chat's prompt, `wisp-tui`'s dialog for its own
   conversation, and the MCP client's elicitation are the face that asked, and ask for no presence. An MCP client
   that answers its own elicitation without the person is outside what wisp can tell, and `mcp.md` says so. That is
   how the person approves today: every one of the 82 approvals over MCP in the audit log to 2026-11-05 was answered
   through Claude Code's elicitation, none through `wisp approvals`, `wisp-tui`, or `/approvals`
   ([measurements.md](../measurements.md), "The git thread's slow turns and its approvals"), so points 2 and 4 guard
   the other routes and what is kept, not the approvals given most often. The alternative, `wisp mcp` asking for the
   person's presence itself once the client's dialog says yes, was weighed and declined by the operator on
   2026-11-09: a second step on every approval through the client, for a client the person already chose to trust
   with the dialog.
4. **What wisp acts on unattended is signed when it is written.** A remembered approval (`approvals.json`), a permanent
   fact (`facts.json`), and the policy-bearing settings (`commandPolicy` and `approval` in `config.json`) are signed
   when wisp writes them, which asks for the person's presence: choosing "This project" asks once more than today.
   wisp keeps the signed copy beside each file. On reading, an entry or setting whose signature does not check is not
   used: a remembered approval is asked again, a permanent fact is not loaded, and a changed setting is reported by
   `wisp doctor` while wisp runs on the signed copy, until `wisp config confirm`, in the person's presence, adopts it.
5. **A missing key is reported, not quietly replaced.** If the keychain item is gone, wisp says so, makes a new key in
   the person's presence, and treats every earlier signature as unchecked, so the person confirms the settings and
   every remembered approval is asked again. Deleting the key costs an agent its effort and the person some prompts; it
   grants nothing.
6. **Reading stays open, and the docs say so.** Threads, the audit log, facts, and the output store stay readable by a
   process running as the person, directly or through `wisp`, MCP resources, and `wisp-tui`. Asking for presence to
   read would break those faces and stop no one reading the files.
7. **No encryption at rest in the first build.** It would keep files copied out of `~/.wisp` (a backup, a sync) from
   being read, but not a process that runs `wisp`, unless point 6 were reversed; much of what wisp keeps comes from
   files the same process can read anyway. It is reconsidered if a copy out of the home becomes the concern.
8. **The home stays `~/.wisp`.** For a program that is not sandboxed, a folder's location does not change who may
   write it; the protection is the key, wherever the files are. ADR 0072's open point is closed this way.

## Probes before building

Run on this Mac with the release's Developer ID signature, recorded in [measurements.md](../measurements.md):

1. From `wisp`, signed as released (hardened runtime, no entitlements): make a Secure Enclave key that requires
   presence, sign with it, and see the prompt; from a terminal, from `wisp chat --json` under `wisp-tui`, and from
   `wisp mcp` started by a client. If the Enclave needs an entitlement a Developer ID tool cannot have, point 1 falls
   back to a keychain-held key behind LocalAuthentication, and this ADR is revised before it is agreed.
2. The keychain item: whether another program (an ad hoc build, a script) can read, replace, or delete it, and what
   the person is shown.
3. The prompt: how much of a command it shows, and how it reads, since an agent can start it unbidden.
4. Over SSH, with no one at the Mac: what the prompt does. If it cannot be answered, the out-of-band answers that grant
   are unavailable there, which is said.

## Consequences

- A same-user agent can no longer answer for the person, grant itself a remembered approval, admit a permanent fact,
  or change the policy wisp runs on, without the person agreeing at a prompt. It can still do anything the person's
  account can do without wisp, read what wisp keeps, start a prompt the person must refuse, and refuse requests.
- The person sees more prompts: one per approval given outside the asking face, one per "This project" grant, and one
  per policy change. Session approvals, held in memory only, ask none.
- Answering from a terminal with no one at the Mac stops working where the prompt cannot be shown (probe 4).
- Tests never need the Enclave: signing goes through a protocol, given a software key in tests, as `ScriptedModel`
  stands in for a model. The Enclave path is covered by the probe and a live test outside the gate.
- Development builds, signed ad hoc, cannot read the release's keychain item; they use a key of their own, and
  `wisp doctor` names which.
- Stored grants (ADR 0078) and briefs can then be signed the same way, which is what they wait on.
- New audit fields: whether an answer was signed, and why one was refused; new event kinds, if any, go in
  [logging.md](../logging.md) when built.
