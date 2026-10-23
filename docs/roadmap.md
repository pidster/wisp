# Roadmap

The releases planned from 0.16.0 to 0.23.0, agreed with the operator on 2026-10-01, have all shipped, and so have
0.23.1 and 0.24.0 (the inquiry verb), on 2026-10-12, 0.24.1, a patch of small items, and 0.24.2, command time
limits, on 2026-10-14, and 0.25.0, an approved run outside the sandbox and the documentation site, on 2026-10-15.
What each carried is in [CHANGELOG.md](https://github.com/pidster/wisp/blob/main/CHANGELOG.md). 0.26.0, the model's
thinking set from chat and a status line that reads the version control off the prompt's path, shipped on
2026-10-15, and 0.26.1 and 0.26.2, a help mode and the parts of a turn set apart, the same day; 0.26.3, four
fixes found while mapping the thread store, on 2026-10-16, and 0.26.4, llama.cpp's thinking on a par with Ollama's,
on 2026-10-18; 0.27.0, one thread store, every thread saved and resumed by any face, on 2026-10-19, and 0.27.1, two fixes to the answer reader and the facts blocks, the same day; 0.27.2, a call's time limit only lengthening the thread's and clearer tool lines in `wisp-tui`, on 2026-10-20; 0.28.0, the thread store's phase 3, `wisp threads`, `/resume`, and a thread picker in `wisp-tui`, on 2026-10-22. 0.29.0, `wisp-tui`'s conversation in a pane of its own, with long outputs folded, each element reachable from the keyboard, and copying, shipped the same day. 0.29.1, the release's optional signing and notarisation, off by default, and `wisp doctor`'s signature line, shipped the same day too. 0.30.0, `Wisp Notifier.app`, notifications from wisp itself as "Wisp" with its own icon, shipped the same day as well. 0.30.1, the first release signed with a Developer ID and notarised, signing on by default, shipped on 2026-10-23. 0.31.0, `Wisp.app` in a signed and notarised disk image, with `wisp install`, `wisp update`, and each package declaring its layout, shipped the same day. Each release carries one or two larger items and a few smaller ones; a small item sits with the larger
one it touches. These are plans, not commitments: an item may move when its work shows it should, and the page is
edited when it does. When an item ships it leaves this page for the changelog, and anything not yet scheduled stays
in [backlog.md](backlog.md). Each release's preflight runs the eval's floors, as a guard against regressions, not a
measurement.

## 0.31.1: `wisp models uninstall`

Moved from 0.31.0 by the operator on 2026-10-23, so 0.31.0 shipped with the disk image, `wisp install`, and
`wisp update`, and 0.31.1 is also the first release a `Wisp.app` updates to with `wisp update`.

Built 2026-10-23 ([ADR 0075](decisions/0075-wisp-models-uninstall.md)), with a real folder moved to the Bin and
`--purge-cache` removing the repository's whole folder, as the operator chose, and leaving a store another tool keeps at
the cache's root to that tool.

**`wisp models uninstall NAME`**, asked for by the operator on 2026-10-23, run by the person only (chat's
`/models uninstall` too; the model's `models` tool cannot): it removes a model where wisp knows its files, Ollama's
through Ollama's own delete, an MLX model's entry in the models folder, and a Core AI bundle, and clears the
model's entries in `config.json` (its settings, a disabled entry). It first shows what goes: the paths, the bytes,
the configuration it clears, and a warning when the model is the default. The person types the model's name to
confirm; `--yes` skips that for a script, and without a terminal nothing is removed unless `--yes` is given. An
MLX model linked into the Hugging Face cache leaves the cache alone unless `--purge-cache` is given, which warns
that other tools sharing the cache lose it too and says how much it frees. llama.cpp's and LM Studio's models are
their servers', and Apple's are the system's: refused, saying where to remove them.

Later, with no release yet: protecting wisp's state from other agents, and Private Cloud Compute, below.

## Later: protecting wisp's state from other agents

Raised by the operator on 2026-10-23: wisp, being on the device, may be trusted with what other agents are not, so
what keeps them out? Today very little does. macOS separates processes by user, not by program, so any agent with a
shell as the same person (Claude Code, Codex, a script) can read `~/.wisp` (threads, the audit log with commands'
output verbatim, facts, the output store), change `config.json`'s policy and threshold or the stored approvals, write
an answer into `~/.wisp/pending` for a request that waits, which defeats [ADR 0046](decisions/0046-approval-and-notifications-over-mcp.md)'s
rule that the asking agent never answers, and run `wisp` itself to print what it keeps.

Moving the whole of wisp to the App Store, so the App Sandbox's container protects its data, was weighed and set
aside: inside the App Sandbox `sandbox-exec` cannot run (nested profiles are refused), commands cannot run in the
person's repositories without a grant for each folder, and a sandboxed command-line tool runs only when its own app
starts it, so another agent could not start `wisp mcp`. What macOS offers a Developer ID tool instead:

- the hardened runtime, on since 0.30.1, which stops another process attaching to `wisp` or injecting code;
- App Management, which stops other apps changing a signed app in `/Applications` (`Wisp.app`, from 0.31.0), where
  Homebrew's Cellar has no such guard;
- keychain items whose access is limited to wisp's code signature, which another program cannot read without the
  person agreeing;
- the person's presence, by Touch ID or password through LocalAuthentication, which an agent cannot supply.

The plan, for a release not yet chosen, with an ADR first that says plainly what a same-user agent can still do:

1. **Answers only the person can give need the person present.** An approval, a fact kept as permanent, and an answer
   to the model's question, given anywhere but the face that asked, are confirmed with Touch ID or the password and
   signed with a key held in the keychain; an answer in `~/.wisp/pending` without that signature is refused.
2. **Policy-bearing state is authenticated.** Configuration changed through `wisp config`, and the stored approvals,
   carry a keychain-held key's authentication code; a change made around wisp is reported by `wisp doctor` and
   refused until the person confirms it.
3. **Encryption at rest, if it earns its cost:** the audit log, threads, and output store, under a keychain-held key,
   so files copied out of `~/.wisp` are unreadable; it does not stop an agent running `wisp`, which point 4 is for.
4. **Reading what wisp keeps.** Whether commands that print threads, facts, or the audit should ask for the person's
   presence when not run from a terminal the person holds, and how wisp can tell.
5. **Where the home belongs.** Left open by [ADR 0072](decisions/0072-a-dmg-and-a-declared-layout.md): `~/.wisp`, or
   Apple's `~/Library/Application Support` and `~/Library/Caches`, decided with the rest, since keys and encryption
   may change what is kept where.

## Later: Private Cloud Compute

Researched on 2026-10-23, and not possible yet for a tool distributed as wisp is. What Apple documents:

- The entitlement, `com.apple.developer.private-cloud-compute`, is granted to a developer account that is in the
  App Store Small Business Program, under two million first-time App Store downloads, and has asked for it by
  Apple's request form; it then appears as a capability for the account's App IDs
  ([Accessing Private Cloud Compute](https://developer.apple.com/private-cloud-compute/)).
- Distribution is through the App Store, tested through TestFlight or ad hoc builds. Developer ID is not named; asked
  on Apple's forums, an Apple engineer thought it is not allowed, without confirming.
- A restricted entitlement on a bare executable needs a bundle with an embedded provisioning profile (Apple's
  pattern for daemons); a command-line binary on its own cannot carry it, signed or not ([backends.md](backends.md),
  "Private Cloud Compute").
- Each person has a daily limit, against their Apple Account, raised by iCloud+; `quotaUsage` reports it. The window
  is 32K tokens. Free to developers for now; Apple says a fee may follow. Use is under the Apple Intelligence terms.
- Calling Apple's `fm` command for it is not a way round: its licence forbids programmatic use, and the `fm` on this
  Mac (macOS 27.0) lists only the on-device model.

The likely shape, unproven: a small helper app of wisp's own holding the entitlement, which makes only the model
call, while wisp's tools, sandbox, approvals, and audit stay in `wisp`. Distributed through the App Store, it must
run in the App Sandbox, and whether a sandboxed helper may serve a command-line client, and App Review accept one
that does, are both open.

Steps for the operator, in the developer portal, before any code: join the Small Business Program; request the
entitlement; once granted, register an App ID (for instance `com.pidster.wisp.cloud`) with the capability; make an
Apple Development certificate, register this Mac, and make a development profile; and try making a Developer ID
profile with the capability, which settles whether the simpler route exists.

Then a probe, `PCCProbe.app`, settles the rest before an ADR: it logs its own entitlements, the model's
availability, quota, and window, and makes one request, run through `open`, as its executable directly, and through
a link in a `bin` folder; again signed with the Developer ID if a profile allows it; and again in the App Sandbox,
answering one request from a plain command-line client over a local socket.

## Not scheduled

Every item in [backlog.md](backlog.md) not yet given a release, grouped by what it waits on.

Waiting on data:

- a small specialised distiller, and a tool-choice classifier, once the audit log holds enough labelled
  pairs (`Falcon-H1-Tiny-Tool-Calling-90M`, pulled on 2026-10-04, is the experiment for the second);
- classifiers from other providers: embedding nearest-neighbour over labelled examples, or an external
  process speaking JSON Lines; and classifiers for other tasks: personal data for `redact`, log-line
  categories.

Waiting on a measurement run:

- the rest of what [ADR 0052](decisions/0052-mlx-on-a-par-with-ollama.md) lists under "What 0.20.0 must
  measure", beyond the `Qwen3-1.7B-4bit` comparison 0.20.0 ran: prefix reuse, the cache's real cost per token,
  the windows sized for common models, the pull against the real Hub, and Core AI past its bundle's window;
- LM Studio against a real LM Studio server ([ADR 0058](decisions/0058-a-shared-http-executor.md)); llama.cpp's
  executor was measured against a real `llama-server` on 2026-10-17 ([measurements.md](measurements.md)).
- the verification pass's model step (`verification.mode: model`), built and off by default: it is turned on only
  when, on the default model, it flags no honest reply and a verdict takes under 3 s; on the on-device model on
  2026-10-12 it flagged 6 of 14 honest replies (p50 1.9 s). It waits on a more capable model, or a narrower prompt
  that leaves plans and explanations alone, measured with `scripts/check eval compare`
  ([ADR 0060](decisions/0060-a-verification-pass.md), "Measured, 2026-10-12").

Waiting on the operator:

- the hand test of the client's question form (ADR 0062, D8; the procedure is in [mcp.md](mcp.md), "Questions"),
  still to run; once it passes, `inquiry.elicitation` may default on. Whether a question's banner should then wait
  for the dialog as an approval's does (`approval.bannerDelaySeconds`) is open: today it is posted at once, and
  waiting would need an amendment to [ADR 0062](decisions/0062-the-inquiry-verb.md).

Waiting on Apple:

- Private Cloud Compute: the entitlement, and whether a helper app distributed outside the App Store may hold it
  (above, "Later: Private Cloud Compute").

Waiting on someone asking:

- action buttons on wisp's notifications ("Show" opening the audit), which `Wisp Notifier.app` could add;
- tools for embeddings and reranking;
- reverse delegation through MCP sampling: the local model asks the calling agent's model when it is
  stuck on a sub-step;
- the deferred uses: bulk classification, and offline work (git chores shipped on 2026-09-24 as
  `draft_change` and `wisp draft`).
