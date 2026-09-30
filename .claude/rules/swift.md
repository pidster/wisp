---
paths:
  - "harness/**/*.swift"
  - "harness/Package.swift"
---

# Swift guidance for the harness

## Toolchain

- macOS 27 and Xcode 27 as the active developer directory. The Command Line Tools lack the `@Generable`
  macro plugin. `PackageDescription` has no `.v27`, so the platform is written `.macOS("27.0")`.
- swift-tools-version 6.2; Swift 6 language mode; strict concurrency is on and stays on.

## Concurrency

- Fix data-race diagnostics by restructuring. Never `@unchecked Sendable`, never `nonisolated(unsafe)`.
- `LanguageModelSession` is not `Sendable`. `Agent` owns it as a plain `final class` and its async methods
  are `nonisolated(nonsending)`, so an actor (`ConversationThread`) can own an `Agent`. New async APIs on
  types that hold a session follow the same pattern.
- Actor when operations suspend or a change is a multi-step sequence that must not interleave
  (`ApprovalGate`, `ApprovalStore`, `ThreadStore`); `final class` with a `Mutex` when every operation is a
  short synchronous critical section (`TurnClock`, `AuditLog`, `SessionApprovals`). `docs/design.md`
  "Concurrency" has the rule; follow it rather than choosing per file.
- Shared mutable state uses `Mutex` from `Synchronization`. `Mutex` is non-copyable: hold it in a
  `final class … : Sendable` with a `let` (see `OutputBuffer`, `ClientCapabilityFlags`), never as a struct
  stored property or a closure capture.
- `public` only for what `WispMCP` or `wisp` calls, an extension-point protocol, or a type a public
  signature exposes; everything else internal (tests use `@testable import`). Folders in `WispCore`
  group by concern (`Session/`, `Exec/`, `Approval/`, `Audit/`, `Facts/`, `Tools/`, `Config/`, `CLI/`,
  `Support/`); put a new file where its neighbours are.
- Do not wrap session work in `Task.detached` or an `AsyncThrowingStream` closure; streaming is a delta
  callback on the caller's task (ADR 0003).
- Foundation formatters (`ISO8601DateFormatter`, `JSONEncoder`) are not `Sendable`; use value-type format
  styles (`Date.ISO8601FormatStyle`) or create coders per use.

## Framework facts

- Every tool is a `struct` conforming to `FoundationModels.Tool` with an `@Generable` `Arguments` type and
  `@Guide` on each property. `name` is `snake_case` and stable; `description` is prompt text, written for
  the model and kept short.
- `@Generable` rejects extra protocol conformances on the same declaration; add `Comparable` and friends in
  an extension (see `RiskLevel`).
- Tool `Output` is `String`. Return failures the model should react to as text (`"error: …"`), do not throw;
  a thrown error aborts the whole response with a raw framework message.
- Use `LanguageModelError` (macOS 27), not the deprecated `LanguageModelSession.GenerationError`.
- Doc comments: `///` on every declaration a reader could need, including private members; `- Parameters:`
  (plural) and `- Throws:` sections are validated by the linter.

## Errors

- Typed `enum … : Error, CustomStringConvertible, Equatable`, one per subsystem (`CommandRunner.Failure`,
  `FileReader.Failure`, `Session.Failure`). No `fatalError` or `print` in `WispCore` or `WispMCP`; the
  CLI target is the only place that renders to stderr, and never to stdout while serving MCP.

## Tests

- swift-testing (`@Suite`, `@Test`, `#expect`). `#expect`'s message argument is a `Comment`: write
  `"\(value)"`, not a `String` variable.
- Tests never need the model. Put logic in pure functions or generic types (`ThreadStore<Thread>`,
  `Transcript.condensed`, `CommandRunner.tail`) and test those. `ModelEvalTests` is the one exception and
  runs only under `WISP_MODEL_TESTS=1` (`scripts/check eval`).
- Tests drive the real Seatbelt sandbox: write only under the working directory and
  `FileManager.default.temporaryDirectory`; a "blocked" path must be outside both (the home directory).
- A computed property that builds a `Transcript` mints new entry ids each access; bind it to a `let`
  before comparing ids.

## Formatting and editing

- `scripts/check format` before committing; lint is `--strict`. 4-space indent, 120 columns.
- swift-format reflows long lines. When patching by exact string replacement, re-read the file after
  formatting; the text you remember is often no longer there.
