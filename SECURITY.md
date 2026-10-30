# Security policy

wisp lets a language model run commands on your Mac, so its protections are the product. This page says how to
report a weakness in them, and what counts as one.

## Reporting a vulnerability

Report it privately through GitHub: on [pidster/wisp](https://github.com/pidster/wisp), open the **Security** tab and
choose **Report a vulnerability**. Please do not open a public issue, pull request, or discussion for it.

Include what you can of:

- the version (`wisp --version`) and how it was installed (`Wisp.app`, Homebrew, or a build), and the macOS version;
- what you did, what happened, and what you expected, with the smallest steps that reproduce it;
- the relevant lines of `wisp logs --json` or `wisp doctor`, with secrets and personal paths taken out.

You will get an acknowledgement, and the report is discussed with you in the private advisory until a fix is
released. Credit in the advisory and the changelog is yours if you want it.

## Supported versions

Only the latest release gets security fixes. A fix ships as a new patch release; `wisp update` (for `Wisp.app`) or
`brew upgrade pidster/tap/wisp` moves you to it. There are no maintenance branches for older versions.

## What is in scope

What wisp promises, and what a vulnerability would break, is set out in
[What wisp can do to your Mac](docs/trust.md). In short, reports like these are in scope:

- a command the model chooses running without the approval the policy and classifier require, or escaping the
  Seatbelt sandbox, or running despite the deny list;
- the model, or a process acting for it, answering its own approval request, approving a `llama-server` binary, or
  changing settings that only the person may change;
- an MCP client, or text the model reads (a file, a web page, command output), causing any of the above;
- anything wisp writes, such as the audit log, facts, threads, the approval store, or wisp's llama.cpp server's key,
  being readable or writable by other users, or a secret being written to a log;
- wisp's llama.cpp server answering without its key, or listening on anything but `127.0.0.1`;
- a released binary, `Wisp.app`, or `wisp update` accepting something not signed by wisp's Developer ID and notarised.

## What is not

- What the switches that remove protection do once you pass them: `--yes`, `--unsafe`,
  `approval.threshold: "never"`, `outsideSandbox` and `!!` runs you approve, and `audit.enabled: false`
  ([the trust page](docs/trust.md#switches-that-remove-protection) lists each).
- A model's answer being wrong, or a model doing something you approved.
- Other processes running as you: wisp's state in `~/.wisp` is not yet protected from other software you run (the
  roadmap's "protecting wisp's state from other agents"), and Llama.app's server, which `llamacpp.server llama-app`
  uses, has no key by its own design.
- Weaknesses in macOS, Ollama, llama.cpp, LM Studio, or a model, unless wisp makes them worse; report those upstream.
