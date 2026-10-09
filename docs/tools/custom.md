# Custom tools

Your own tools for the model, declared in `~/.wisp/config.json`: a command line with `{placeholders}`
and the typed arguments that fill them. The model sees an ordinary tool; a call substitutes the values
and runs the line exactly as `run_command` would, through the policy, classifier, approval, sandbox, and
audit. Only your own config can define them; a project cannot. Decided in
[ADR 0036](../decisions/0036-custom-tools.md).

```json
{
  "tools": {
    "disabled": ["notify"],
    "custom": [
      {
        "name": "issue",
        "description": "Shows a GitHub issue of the current repository.",
        "arguments": { "number": { "type": "integer", "description": "The issue number" } },
        "command": "gh issue view {number}"
      },
      {
        "name": "line_head",
        "description": "Shows the first lines of a file.",
        "arguments": {
          "path": { "type": "string", "description": "The file" },
          "lines": { "type": "integer", "description": "How many lines", "default": 5 }
        },
        "command": "head -n {lines} {path}",
        "timeoutSeconds": 10
      }
    ]
  }
}
```

## Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | What the model calls it: snake_case, up to 40 characters, not a built-in's name, not repeated. |
| `description` | yes | What the model is told it does, 1 to 300 characters. Write it for the model, as a sentence. |
| `arguments` | no | By name (snake_case): `type` (`string`, `integer`, `number`, `boolean`), `description`, `enum` (strings only), `default` (makes it optional). |
| `command` | yes | Run with `/bin/sh -c`. Every `{name}` must be a declared argument, and every argument must appear. |
| `workingDirectory` | no | Where it runs; `~` expands. Default: where wisp runs. |
| `timeoutSeconds` | no | Default: `commandTimeoutSeconds`. |

`tools.disabled` lists built-in tools to leave out: `current_date`, `run_command`, `read_file`,
`edit_file`, `inspect`, `notify`, `system_info`.

## How a call runs

Values are substituted into the command: strings single-quoted, so a value cannot break out of its
argument (`it's` becomes `'it'\''s'`), and checked against the `enum`; integers, numbers, and booleans
as written. Substitution is one pass over the template, so a value that holds another placeholder (`{b}`) stays
text and is never filled in itself (before 0.21.1 it was, which let one value unquote another). A missing required value or one of the wrong type comes back to the model as `error: …`
without running anything. The substituted line then goes through `run_command`'s runner: the policy's
deny patterns, the risk classifier and approval (judged on the substituted line, so a template that
writes, installs, or reaches the network is asked about as the same command would be), the sandbox, the timeout, and the output bound. The result is `run_command`'s:
the exit status and bounded output. Every call is audited as `tool.call`, and its command as
`classifier.verdict` and `command.outcome` ([logging.md](../logging.md)).

## Checking

A bad definition makes the config malformed, and every command says which tool and why:

```
Error: malformed ~/.wisp/config.json: custom tool 'issue': the command uses {num}, which is not a declared argument
```

`wisp tools` lists the tools a session gets, custom ones last; `wisp tools --markdown` shows each one's
limits and an example prompt, as the MCP resource `wisp://tools.md` does.
