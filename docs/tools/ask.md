# ask

Lets the model ask you one question in the middle of a turn and go on with your answer: which of two things you
meant, or a value it cannot find. A question is not a permission: no answer runs anything, and every command the
model runs afterwards still passes the policy, the classifier, the gate, and the sandbox. Decided in
[ADR 0062](../decisions/0062-the-inquiry-verb.md); the inquiry effect each face carries is in
[ADR 0044](../decisions/0044-host-effects.md)'s terms.

**Off by default.** Like `memory` and `models`, a conversation gets it only when its tool list names it or the
setting turns it on for every conversation given every tool:

```
wisp config set tools.ask true
```

or `/config set tools.ask on` in chat, or `"tools": { "ask": true }` in `~/.wisp/config.json`; it applies from the
next conversation.

| Conversation | `ask` |
| --- | --- |
| Every tool (no `--tool`, MCP `respond` without `tools`, chat), `tools.ask` off (the default) | No |
| Every tool, `tools.ask: true` | Yes |
| A named list (`--tool ask`, MCP `tools: ["ask"]`) | Only when the list names it, whatever the setting says |
| `tools.disabled: ["ask"]` | No, anywhere |

So the MCP git thread of `AGENTS.md` (`tools: ["run_command"]`) never sees it.

## Contract

| Field | Value |
| --- | --- |
| Name | `ask` |
| Description (what the model sees) | Ask the person one question when you cannot go on without their answer: which of two things they meant, or a value you cannot find. Not for permission (commands ask for themselves), not for secrets. Give options when there are few. |
| `question` | The question, 1 to 300 characters, one paragraph |
| `options` | For a choice: 2 to 6 options of up to 80 characters each, all different. Left out for free text |

| Shape | You answer | The model gets |
| --- | --- | --- |
| Free text (no `options`) | A line of text | `answer: <text>`, then `(from the person)` |
| A choice | One option, or `none of these` | `chose: <option>`, or `the person chose none of these options` |
| Yes or no | A choice of `yes` and `no` | `chose: yes` |

Every other outcome is a fixed line the model can read: `the person declined to answer. Do not ask this again; say
in your reply what you needed`; `no answer within 5 min. Do not guess what the person would say. Say in your
reply what you need, and stop` (only when a deadline is set); `no person can answer here (wisp respond); say in
your reply what you need`; under `wisp mcp`, `waiting for the person: "…" (question a1b2c3d4). Their answer
reaches you as a note on a later turn. Do not guess it. …` ([../mcp.md](../mcp.md), "Questions"). Silence is
never an answer: the model is told to stop, and the verification pass flags a reply that says you chose or
confirmed something when no question was answered ([../verification.md](../verification.md)).

## Limits and controls

| Control | Value |
| --- | --- |
| Waiting | One question at a time on a thread; a second `ask` while one waits is `error: a question is already waiting for the person; …` |
| Per turn | Two; a third is `error: you have asked 2 questions this turn; say in your reply what you still need, and stop`. The same question twice in a turn is refused |
| Secrets | A question that asks for a password, passphrase, token, API key, secret, private key, PIN, one-time or 2FA code, credentials, access key, or login details is refused by rule before anyone sees it: `error: ask does not ask for secrets; tell the person what is needed and where to set it`. The rule can be talked round ("the thing you log in with"), so the answer is scanned too: a credential-shaped value in your answer (the `secret` rules of [scan_secrets](../mcp.md)) is replaced by its numbered marker, `[REDACTED:aws-access-key#1]`, in what the model gets and everywhere wisp records the answer, and chat tells you it was not passed on |
| The answer | Up to 2,000 bytes; longer is cut with a note |
| How long | `inquiry.timeoutSeconds`, default `0`: until you answer, however long you are away. A positive value, 10 to 86,400, sets a deadline; past it the question ends `unanswered` and the model is told to stop |
| Shown as | The model's: escaped (control characters and bidirectional overrides written as `\e`, `\u{202E}`), labelled "the model asks", never styled as an approval and never offered an approval's keys, so a question such as "Approve `rm -rf build`? [y/n]" cannot pass for wisp's own gate |
| Audit | `inquiry.requested` and `inquiry.settled` on the asking thread, with the answer verbatim (markers applied), and the `ask` call's `tool.call` and `tool.result` as for every tool; under `wisp mcp` also `inquiry.parked`, and `inquiry.answered` in the process you answered from ([../logging.md](../logging.md)) |
| Fact | An answer becomes a fact of the thread, subject `answer`, named by the question (cut to 80 characters), source `person`, so condensing never loses it; never permanent on its own ([../context-management.md](../context-management.md), "Facts") |

## How each face asks

| Face | The dialog | You answer |
| --- | --- | --- |
| Plain chat | On the terminal, under `? the model asks`: the question, then the numbered options with `none of these` last, then a prompt. Read in a way Ctrl-C and the deadline can end, so the turn waits for you as long as you take | A number or the text; Enter alone declines; Ctrl-C stops the turn |
| `wisp chat --json`, `wisp-tui` | A `choice` line with `kind: "question"` (and `acceptsText` for free text), which `wisp-tui` shows as a picker titled "the model asks", with where the answer goes | The `choose` line; Esc declines, Ctrl-C declines, a second Ctrl-C stops the turn |
| `wisp mcp` | Filed in `~/.wisp/pending/<id>.question.json` and announced by one notification, "wisp: the model asks" ("Which config? — wisp questions answer a1b2c3d4"); with `inquiry.elicitation` on (off by default), the client's dialog too. The call holds for 60 s, then the turn parks and the answer reaches the thread's next turn ([../mcp.md](../mcp.md), "Questions") | `wisp questions answer ID` from a terminal, which prompts for the text, or a running `wisp-tui`; `wisp questions decline ID` |
| `wisp respond`, `--yes` | Not asked | `ask` returns `no person can answer here` at once |

Who may answer: you, in one of wisp's faces. The agent that called `wisp mcp` cannot: nothing in the MCP
conversation answers a question, wisp's own model is refused `wisp questions answer|decline` by the default
policy and cannot write `~/.wisp` from the sandbox, and the command runs only from a terminal
([../trust.md](../trust.md)). Your answer is not private from that agent: a thread's output, context, facts, and
audit are readable through `wisp://threads/{thread_id}`, and the dialog says so.

## Example

```
› Replace the config with the new defaults.

  ⚙ ask Which config did you mean?

? the model asks
  Which config did you mean?
  1  ~/.wisp/config.json
  2  ./wisp.json
  3  none of these
  type a number, or press Enter to decline › 2
```

The model gets `chose: ./wisp.json` and goes on in the same turn; the answer is `c4 answer "Which config did you
mean?" = ./wisp.json` among the turn's facts.
