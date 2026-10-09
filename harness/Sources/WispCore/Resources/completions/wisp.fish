# wisp completions: generated from wisp's commands by scripts/check completions; wisp completions install replaces only a file with this line.
function __wisp_should_offer_completions_for_flags_or_options -a expected_commands
    set -l non_repeating_flags_or_options $argv[2..]
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __wisp_parse_tokens
    test "$commands" = "$expected_commands"; and return $non_repeating_flags_or_options_absent
end

function __wisp_should_offer_completions_for_positional -a expected_commands positional_index_comparison expected_positional_index
    set -l non_repeating_flags_or_options
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __wisp_parse_tokens
    test "$commands" = "$expected_commands" -a \( "$positional_index" "$positional_index_comparison" "$expected_positional_index" \)
end

function __wisp_parse_tokens -S
    set -l unparsed_tokens (__wisp_tokens -pc)
    switch $unparsed_tokens[1]
    case 'wisp'
        __wisp_parse_subcommand 0 'version' 'h/help'
        switch $unparsed_tokens[1]
        case 'respond'
            __wisp_parse_subcommand 1 'i/instructions=' 'tool=+' 'no-tools' 'unsafe' 'm/model=' 'stream' 'no-stream' 'y/yes' 'schema=' 'version' 'h/help'
        case 'chat'
            __wisp_parse_subcommand 0 'i/instructions=' 'tool=+' 'no-tools' 'unsafe' 'm/model=' 'y/yes' 'r/resume=' 'save=' 'list' 'json' 'plain' 'version' 'h/help'
        case 'tools'
            __wisp_parse_subcommand 0 'json' 'markdown' 'version' 'h/help'
        case 'models'
            __wisp_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __wisp_parse_subcommand 0 'all' 'no-tools' 'json' 'version' 'h/help'
            case 'enable'
                __wisp_parse_subcommand -r 1 'version' 'h/help'
            case 'disable'
                __wisp_parse_subcommand -r 1 'version' 'h/help'
            case 'check'
                __wisp_parse_subcommand -r 1 'version' 'h/help'
            case 'pull'
                __wisp_parse_subcommand 1 'trust-publisher' 'version' 'h/help'
            end
        case 'mcp'
            __wisp_parse_subcommand 0 'i/instructions=' 'tool=+' 'no-tools' 'unsafe' 'm/model=' 'y/yes' 'version' 'h/help'
        case 'logs'
            __wisp_parse_subcommand 0 'session=' 'kind=+' 'tool=' 'l/last=' 'json' 'f/follow' 'version' 'h/help'
        case 'config'
            __wisp_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'show'
                __wisp_parse_subcommand 0 'version' 'h/help'
            case 'list'
                __wisp_parse_subcommand 0 'version' 'h/help'
            case 'get'
                __wisp_parse_subcommand 1 'version' 'h/help'
            case 'set'
                __wisp_parse_subcommand -r 2 'version' 'h/help'
            case 'unset'
                __wisp_parse_subcommand 1 'version' 'h/help'
            end
        case 'doctor'
            __wisp_parse_subcommand 0 'version' 'h/help'
        case 'approvals'
            __wisp_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __wisp_parse_subcommand 0 'version' 'h/help'
            case 'revoke'
                __wisp_parse_subcommand 1 'version' 'h/help'
            case 'clear'
                __wisp_parse_subcommand 0 'version' 'h/help'
            case 'pending'
                __wisp_parse_subcommand 0 'version' 'h/help'
            case 'approve'
                __wisp_parse_subcommand 1 'scope=' 'version' 'h/help'
            case 'deny'
                __wisp_parse_subcommand 1 'version' 'h/help'
            end
        case 'facts'
            __wisp_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'pending'
                __wisp_parse_subcommand 0 'version' 'h/help'
            case 'keep'
                __wisp_parse_subcommand 1 'version' 'h/help'
            case 'drop'
                __wisp_parse_subcommand 1 'version' 'h/help'
            end
        case 'notify'
            __wisp_parse_subcommand 1 't/title=' 'subtitle=' 'sound' 'route=' 'version' 'h/help'
        case 'scan'
            __wisp_parse_subcommand -r 1 'personal' 'thorough' 'm/model=' 'json' 'version' 'h/help'
        case 'redact'
            __wisp_parse_subcommand 1 'secrets-only' 'thorough' 'm/model=' 'version' 'h/help'
        case 'watch'
            __wisp_parse_subcommand 1 'C/directory=' 'path=+' 'no-files' 'every=' 'settle=' 'notify=' 'no-triage' 'max-runs=' 'm/model=' 'y/yes' 'version' 'h/help'
        case 'draft'
            __wisp_parse_subcommand 1 'm/model=' 'y/yes' 'version' 'h/help'
        case 'classifier'
            __wisp_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __wisp_parse_subcommand 0 'version' 'h/help'
            case 'train'
                __wisp_parse_subcommand 0 'examples=' 'from-audit' 'use' 'exclude=+' 'version' 'h/help'
            case 'measure'
                __wisp_parse_subcommand 1 'examples=' 'classifier=' 'coreml-model=' 'version' 'h/help'
            case 'use'
                __wisp_parse_subcommand 1 'version' 'h/help'
            case 'remove'
                __wisp_parse_subcommand 1 'version' 'h/help'
            end
        case 'completions'
            __wisp_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'print'
                __wisp_parse_subcommand 1 'version' 'h/help'
            case 'install'
                __wisp_parse_subcommand 1 'print-path' 'version' 'h/help'
            end
        case 'help'
            __wisp_parse_subcommand -r 1 'version'
        end
    end
end

function __wisp_tokens
    if test (string split -m 1 -f 1 -- . "$FISH_VERSION") -gt 3
        commandline --tokens-raw $argv
    else
        commandline -o $argv
    end
end

function __wisp_parse_subcommand -S -a positional_count
    argparse -s r -- $argv
    set -l option_specs $argv[2..]
    set -l is_repeating_positional $_flag_r
    set -el _flag_r
    set -a commands $unparsed_tokens[1]
    set positional_index 0
    while true
        set -e unparsed_tokens[1]
        argparse -sn "$commands" $option_specs -- $unparsed_tokens 2> /dev/null
        set unparsed_tokens $argv
        set positional_index (math $positional_index + 1)
        for non_repeating_flag_or_option in $non_repeating_flags_or_options
            if set -ql "_flag_$(string replace -a - _ -- $non_repeating_flag_or_option)"
                set non_repeating_flags_or_options_absent 1
                break
            end
        end
        test (count $unparsed_tokens) -eq 0 -o \( -z "$is_repeating_positional" -a "$positional_index" -gt "$positional_count" \) && break
    end
end

function __wisp_complete_directories
    set -l token (commandline -t)
    string match -- '*/' $token
    set -l subdirs $token*/
    printf %s\n $subdirs
end

function __wisp_custom_completion
    set -x SAP_SHELL fish
    set -x SAP_SHELL_VERSION $FISH_VERSION
    set -l tokens (__wisp_tokens -p)
    if test -z "$(__wisp_tokens -t)"
        set -l index (count (__wisp_tokens -pc))
        set tokens $tokens[..$index] \'\' $tokens[(math $index + 1)..]
    end
    command $tokens[1] $argv $tokens
end

complete -c 'wisp' -f
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'respond' -d 'Generate a response to a prompt, calling tools as needed.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'chat' -d 'Start an interactive chat session.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'tools' -d 'List the tools available to the model.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'models' -d 'List, enable, or disable the models usable with --model and config.json, or fetch an MLX model.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'mcp' -d 'Serve wisp\'s tools to an MCP client over stdio.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'logs' -d 'Show the audit log.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'config' -d 'Show or change the configuration.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'doctor' -d 'Check that wisp can run on this Mac.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'approvals' -d 'Show or revoke standing command approvals, and answer commands waiting for approval.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'facts' -d 'Answer requests to keep a fact as a permanent fact.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'notify' -d 'Show a macOS notification.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'scan' -d 'Scan text for credentials and personal data.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'redact' -d 'Redact credentials and personal data from text.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'watch' -d 'Rerun a command when files change, and notify when it starts or stops failing.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'draft' -d 'Draft a commit message, a PR description, or a changelog line from a diff.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'classifier' -d 'Train, measure, and choose risk classifiers for the approval gate.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'completions' -d 'Print or install wisp\'s shell completions for zsh, bash, or fish.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp" -eq 1' -fa 'help' -d 'Show subcommand help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" i instructions' -s 'i' -l 'instructions' -d 'Instructions for this conversation, added under wisp\'s system prompt and config.json\'s extension.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond"' -l 'tool' -d 'Tool to enable (repeatable). All tools are enabled when omitted.' -rfka '(__wisp_custom_completion ---completion respond -- --tool (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" no-tools' -l 'no-tools' -d 'Give the model no tools: a text-only conversation any model can run.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" unsafe' -l 'unsafe' -d 'Disable the run_command policy and sandbox.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" m model' -s 'm' -l 'model' -d 'Model: system, private-cloud, or <backend>:<name> (see wisp models). Defaults to config.json.' -rfka '(__wisp_custom_completion ---completion respond -- --model (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" stream' -l 'stream' -d 'Stream the output as it is generated.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" no-stream' -l 'no-stream' -d 'Stream the output as it is generated.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" y yes' -s 'y' -l 'yes' -d 'Approve risky commands without asking (non-interactive).'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" schema' -l 'schema' -d 'Path to a JSON Schema; the reply is JSON of that shape (not streamed).' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp respond" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" i instructions' -s 'i' -l 'instructions' -d 'Instructions for this conversation, added under wisp\'s system prompt and config.json\'s extension.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat"' -l 'tool' -d 'Tool to enable (repeatable). All tools are enabled when omitted.' -rfka '(__wisp_custom_completion ---completion chat -- --tool (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" no-tools' -l 'no-tools' -d 'Give the model no tools: a text-only conversation any model can run.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" unsafe' -l 'unsafe' -d 'Disable the run_command policy and sandbox.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" m model' -s 'm' -l 'model' -d 'Model: system, private-cloud, or <backend>:<name> (see wisp models). Defaults to config.json.' -rfka '(__wisp_custom_completion ---completion chat -- --model (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" y yes' -s 'y' -l 'yes' -d 'Approve risky commands without asking.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" r resume' -s 'r' -l 'resume' -d 'Resume a saved transcript by name.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" save' -l 'save' -d 'Save the transcript under this name on exit. Defaults to the resumed name.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" list' -l 'list' -d 'List saved transcripts (for --resume) and exit.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" json' -l 'json' -d 'Headless: JSON Lines on stdin and stdout, for a front end such as wisp-tui.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" plain' -l 'plain' -d 'The plain line-based chat, even when wisp-tui is installed beside wisp.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp chat" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp tools" json' -l 'json' -d 'Print the full catalogue (schemas, limits, example prompts) as JSON.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp tools" markdown' -l 'markdown' -d 'Print the full catalogue as Markdown, the same text as the MCP resource wisp://tools.md.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp tools" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp tools" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp models" -eq 1' -fa 'list' -d 'List the models usable with --model and config.json.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp models" -eq 1' -fa 'enable' -d 'Enable models: offered by /model again; a cached MLX model is linked, with no download.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp models" -eq 1' -fa 'disable' -d 'Disable models: hidden from /model and refused everywhere; not the default model.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp models" -eq 1' -fa 'check' -d 'Check what MLX and llama.cpp models can do, on the models themselves, and record it in config.json.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp models" -eq 1' -fa 'pull' -d 'Fetch an MLX model from Hugging Face into its cache and link it, after asking.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models list" all' -l 'all' -d 'Also list the models that cannot be used, with the reason.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models list" no-tools' -l 'no-tools' -d 'List the models usable for a conversation with no tools.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models list" json' -l 'json' -d 'Print the listing as JSON, a field per column.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models list" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp models enable" -ge 1' -fka '(__wisp_custom_completion ---completion models enable -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models enable" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models enable" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models disable" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models disable" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models check" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models check" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models pull" trust-publisher' -l 'trust-publisher' -d 'Pull from a publisher not in mlx.trustedPublishers this once, skipping the question about the publisher; the download question is still asked, and the setting is unchanged.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models pull" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp models pull" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp" i instructions' -s 'i' -l 'instructions' -d 'Instructions for this conversation, added under wisp\'s system prompt and config.json\'s extension.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp"' -l 'tool' -d 'Tool to enable (repeatable). All tools are enabled when omitted.' -rfka '(__wisp_custom_completion ---completion mcp -- --tool (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp" no-tools' -l 'no-tools' -d 'Give the model no tools: a text-only conversation any model can run.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp" unsafe' -l 'unsafe' -d 'Disable the run_command policy and sandbox.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp" m model' -s 'm' -l 'model' -d 'Model: system, private-cloud, or <backend>:<name> (see wisp models). Defaults to config.json.' -rfka '(__wisp_custom_completion ---completion mcp -- --model (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp" y yes' -s 'y' -l 'yes' -d 'Approve risky commands without asking the client\'s user.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp mcp" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs" session' -l 'session' -d 'Only this session id.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs"' -l 'kind' -d 'Only these event kinds (repeatable), e.g. tool.call, policy.decision.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs" tool' -l 'tool' -d 'Only tool events for this tool name.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs" l last' -l 'last' -s 'l' -d 'Only the last N matching events.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs" json' -l 'json' -d 'Print raw JSON Lines instead of one-line summaries.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs" f follow' -s 'f' -l 'follow' -d 'Keep printing matching events as they are written, MCP calls included, until Ctrl-C. Starts with the last 10 unless --last says otherwise.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp logs" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config" -eq 1' -fa 'show' -d 'Print the effective configuration as JSON.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config" -eq 1' -fa 'list' -d 'List the settings \'set\' can change.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config" -eq 1' -fa 'get' -d 'Print one setting\'s value, and whether it is set or the default.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config" -eq 1' -fa 'set' -d 'Set a setting, such as: approval.classifier coreml'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config" -eq 1' -fa 'unset' -d 'Remove a setting so its default applies.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config show" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config show" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config list" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config get" -eq 1' -fka '(__wisp_custom_completion ---completion config get -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config get" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config get" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config set" -eq 1' -fka '(__wisp_custom_completion ---completion config set -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config set" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config set" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp config unset" -eq 1' -fka '(__wisp_custom_completion ---completion config unset -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config unset" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp config unset" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp doctor" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp doctor" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals" -eq 1' -fa 'list' -d 'List standing approvals.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals" -eq 1' -fa 'revoke' -d 'Revoke one standing approval by id.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals" -eq 1' -fa 'clear' -d 'Revoke every standing approval.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals" -eq 1' -fa 'pending' -d 'List commands waiting for approval in wisp mcp servers.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals" -eq 1' -fa 'approve' -d 'Approve a command waiting for approval, from a terminal.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals" -eq 1' -fa 'deny' -d 'Deny a command waiting for approval.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals list" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals revoke" -eq 1' -fka '(__wisp_custom_completion ---completion approvals revoke -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals revoke" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals revoke" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals clear" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals clear" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals pending" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals pending" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals approve" -eq 1' -fka '(__wisp_custom_completion ---completion approvals approve -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals approve" scope' -l 'scope' -d 'once, session, project, or always.' -rfka 'once session project always'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals approve" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals approve" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp approvals deny" -eq 1' -fka '(__wisp_custom_completion ---completion approvals deny -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals deny" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp approvals deny" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp facts" -eq 1' -fa 'pending' -d 'List facts wisp mcp callers asked to keep as permanent facts.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp facts" -eq 1' -fa 'keep' -d 'Keep a fact as a permanent fact, as yours, from a terminal.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp facts" -eq 1' -fa 'drop' -d 'Leave a fact in its thread rather than keep it; the thread does not ask again.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts pending" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts pending" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp facts keep" -eq 1' -fka '(__wisp_custom_completion ---completion facts keep -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts keep" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts keep" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp facts drop" -eq 1' -fka '(__wisp_custom_completion ---completion facts drop -- positional@0 (count (__wisp_tokens -pc)) (__wisp_tokens -tC))'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts drop" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp facts drop" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp notify" t title' -s 't' -l 'title' -d 'The title (default: wisp).' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp notify" subtitle' -l 'subtitle' -d 'A second line under the title.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp notify" sound' -l 'sound' -d 'Play the default notification sound.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp notify" route' -l 'route' -d 'Use only this route: host, terminal, app, or osascript. app is tried even when notifications.viaTerminalApp is off, to probe which app the banner is attributed to.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp notify" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp notify" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp scan" personal' -l 'personal' -d 'Report personal data too: emails, phone and card numbers, public IPs, addresses, private hostnames, user names, and lines the personal-data classifier flags.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp scan" thorough' -l 'thorough' -d 'Also have the model look for what rules cannot recognise: up to three turns of about 2 s per 4 KiB.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp scan" m model' -s 'm' -l 'model' -d 'Model for --thorough. Defaults to routing.tasks.secrets, else the measured default (system).' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp scan" json' -l 'json' -d 'Print the reports as JSON, one per line.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp scan" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp scan" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp redact" secrets-only' -l 'secrets-only' -d 'Replace credentials only and keep personal data.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp redact" thorough' -l 'thorough' -d 'Also have the model find names, addresses, and identifiers: up to three turns of about 2 s per 4 KiB.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp redact" m model' -s 'm' -l 'model' -d 'Model for --thorough. Defaults to routing.tasks.secrets, else the measured default (system).' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp redact" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp redact" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" C directory' -s 'C' -l 'directory' -d 'Directory to run the command in. Default: the current one.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch"' -l 'path' -d 'A directory to watch for changes (repeatable). Default: --directory.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" no-files' -l 'no-files' -d 'Do not watch files; run on the interval only.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" every' -l 'every' -d 'Also run every this many seconds.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" settle' -l 'settle' -d 'Seconds without a file change before a run starts; 0 runs on every change. Default: watch.settle, 1.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" notify' -l 'notify' -d 'When to notify: change (default), failure, always, never.' -rfka 'change failure always never'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" no-triage' -l 'no-triage' -d 'Do not have the model triage a failing run.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" max-runs' -l 'max-runs' -d 'Stop after this many runs.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" m model' -s 'm' -l 'model' -d 'Model for triage. Defaults to config.json.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" y yes' -s 'y' -l 'yes' -d 'Approve risky commands without asking.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp watch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp draft" -eq 1' -fka 'commit pr changelog'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp draft" m model' -s 'm' -l 'model' -d 'Model to write with. Defaults to config.json.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp draft" y yes' -s 'y' -l 'yes' -d 'Approve running git diff without asking.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp draft" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp draft" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp classifier" -eq 1' -fa 'list' -d 'List the risk classifier versions on this Mac.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp classifier" -eq 1' -fa 'train' -d 'Train a new risk classifier version on this Mac from labelled commands.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp classifier" -eq 1' -fa 'measure' -d 'Measure a risk classifier\'s accuracy and speed on labelled commands.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp classifier" -eq 1' -fa 'use' -d 'Use a risk classifier version for the approval gate, from the next session.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp classifier" -eq 1' -fa 'remove' -d 'Remove a risk classifier version trained here; not the default, not the one in use.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier list" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier train" examples' -l 'examples' -d 'Labelled commands to learn from. Defaults to the bundled examples.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier train" from-audit' -l 'from-audit' -d 'Also learn from the on-device model\'s verdicts in this Mac\'s audit log, secrets redacted.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier train" use' -l 'use' -d 'Use the new version at once, as \'wisp classifier use\' would.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier train"' -l 'exclude' -d 'Labelled commands to leave out of training, such as a test set; repeatable.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier train" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier train" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier measure" examples' -l 'examples' -d 'Labelled commands. Defaults to the bundled training examples.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier measure" classifier' -l 'classifier' -d 'rules, system-model, or coreml. Defaults to approval.classifier.' -rfka 'rules system-model coreml'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier measure" coreml-model' -l 'coreml-model' -d 'A Core ML model file for --classifier coreml, instead of a version.' -rfka ''
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier measure" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier measure" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier use" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier use" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier remove" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp classifier remove" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp completions" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp completions" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp completions" -eq 1' -fa 'print' -d 'Print the completion script for a shell (the default).'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp completions" -eq 1' -fa 'install' -d 'Install the completion script where your shell looks for it.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp completions print" -eq 1' -fka 'zsh bash fish'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp completions print" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp completions print" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_positional "wisp completions install" -eq 1' -fka 'zsh bash fish'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp completions install" print-path' -l 'print-path' -d 'Print where the script would go, and write nothing.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp completions install" version' -l 'version' -d 'Show the version.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp completions install" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'wisp' -n '__wisp_should_offer_completions_for_flags_or_options "wisp help" version' -l 'version' -d 'Show the version.'
