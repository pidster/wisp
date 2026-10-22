# tools

Cargo workspace for wisp's tool binaries. Each tool is an ordinary CLI program (arguments in, stdout out,
meaningful exit code) that knows nothing about agents; the harness under `../harness` declares the
model-facing schema and invokes the binary. See `../docs/decisions/0005-tools-as-plain-binaries.md`.

`wisp-tui` is not a tool but a front end: it runs `wisp chat --json` (`docs/wisp.md`, "Headless chat")
and draws the conversation on the alternate screen, in a pane of its own (`src/pane.rs`, the elements held in
`src/transcript.rs`), above a band with the reply in progress, an approval dialog, the input, and the status, in
wisp's palette (`src/palette.rs`), with a one-cell margin and a tinted input row; on quitting it prints the
conversation into the scrollback (ADR 0068). It began as a spike on 2026-09-22
(`docs/proposals/2026-09-22-tui-spike.md`). The Homebrew formula installs it beside
`wisp`, and `wisp chat` hands a terminal session to it (ADR 0029). From a checkout: `cargo build` here and
`WISP_BIN=<path to a wisp with --json> target/debug/wisp-tui [chat arguments]`.

Add a tool: `cargo new --bin <name>` here, list it in `members`, and register a Swift `Tool` for it in
`harness/Sources/WispCore/Tools/`.
