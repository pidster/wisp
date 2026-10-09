#!/bin/bash
# wisp completions: generated from wisp's commands by scripts/check completions; wisp completions install replaces only a file with this line.

__wisp_cursor_index_in_current_word() {
    local remaining="${COMP_LINE}"

    local word
    for word in "${COMP_WORDS[@]::COMP_CWORD}"; do
        remaining="${remaining##*([[:space:]])"${word}"*([[:space:]])}"
    done

    local -ir index="$((COMP_POINT - ${#COMP_LINE} + ${#remaining}))"
    if [[ "${index}" -le 0 ]]; then
        printf 0
    else
        printf %s "${index}"
    fi
}

# positional arguments:
#
# - 1: the current (sub)command's count of positional arguments
#
# required variables:
#
# - repeating_flags: the repeating flags that the current (sub)command can accept
# - non_repeating_flags: the non-repeating flags that the current (sub)command can accept
# - repeating_options: the repeating options that the current (sub)command can accept
# - non_repeating_options: the non-repeating options that the current (sub)command can accept
# - positional_number: value ignored
# - unparsed_words: unparsed words from the current command line
#
# modified variables:
#
# - non_repeating_flags: remove flags for this (sub)command that are already on the command line
# - non_repeating_options: remove options for this (sub)command that are already on the command line
# - positional_number: set to the current positional number
# - unparsed_words: remove all flags, options, and option values for this (sub)command
__wisp_offer_flags_options() {
    local -ir positional_count="${1}"
    positional_number=0

    local was_flag_option_terminator_seen=false
    local is_parsing_option_value=false

    local -ar unparsed_word_indices=("${!unparsed_words[@]}")
    local -i word_index
    for word_index in "${unparsed_word_indices[@]}"; do
        if "${is_parsing_option_value}"; then
            # This word is an option value:
            # Reset marker for next word iff not currently the last word
            [[ "${word_index}" -ne "${unparsed_word_indices[${#unparsed_word_indices[@]} - 1]}" ]] && is_parsing_option_value=false
            unset "unparsed_words[${word_index}]"
            # Do not process this word as a flag or an option
            continue
        fi

        local word="${unparsed_words["${word_index}"]}"
        if ! "${was_flag_option_terminator_seen}"; then
            case "${word}" in
            --)
                unset "unparsed_words[${word_index}]"
                # by itself -- is a flag/option terminator, but if it is the last word, it is the start of a completion
                if [[ "${word_index}" -ne "${unparsed_word_indices[${#unparsed_word_indices[@]} - 1]}" ]]; then
                    was_flag_option_terminator_seen=true
                fi
                continue
                ;;
            -*)
                # ${word} is a flag or an option
                # If ${word} is an option, mark that the next word to be parsed is an option value
                local option
                for option in "${repeating_options[@]}" "${non_repeating_options[@]}"; do
                    [[ "${word}" = "${option}" ]] && is_parsing_option_value=true && break
                done

                # Remove ${word} from ${non_repeating_flags} or ${non_repeating_options} so it isn't offered again
                local not_found=true
                local -i index
                for index in "${!non_repeating_flags[@]}"; do
                    if [[ "${non_repeating_flags[${index}]}" = "${word}" ]]; then
                        unset "non_repeating_flags[${index}]"
                        non_repeating_flags=("${non_repeating_flags[@]}")
                        not_found=false
                        break
                    fi
                done
                if "${not_found}"; then
                    for index in "${!non_repeating_flags[@]}"; do
                        if [[ "${non_repeating_flags[${index}]}" = "${word}" ]]; then
                            unset "non_repeating_flags[${index}]"
                            non_repeating_flags=("${non_repeating_flags[@]}")
                            break
                        fi
                    done
                fi
                unset "unparsed_words[${word_index}]"
                continue
                ;;
            esac
        fi

        # ${word} is neither a flag, nor an option, nor an option value
        if [[ "${positional_number}" -lt "${positional_count}" || "${positional_count}" -lt 0 ]]; then
            # ${word} is a positional
            ((positional_number++))
            unset "unparsed_words[${word_index}]"
        else
            if [[ -z "${word}" ]]; then
                # Could be completing a flag, option, or subcommand
                positional_number=-1
            else
                # ${word} is a subcommand or invalid, so stop processing this (sub)command
                positional_number=-2
            fi
            break
        fi
    done

    unparsed_words=("${unparsed_words[@]}")

    if\
        ! "${was_flag_option_terminator_seen}"\
        && ! "${is_parsing_option_value}"\
        && [[ ("${cur}" = -* && "${positional_number}" -ge 0) || "${positional_number}" -eq -1 ]]
    then
        COMPREPLY+=($(compgen -W "${repeating_flags[*]} ${non_repeating_flags[*]} ${repeating_options[*]} ${non_repeating_options[*]}" -- "${cur}"))
    fi
}

__wisp_add_completions() {
    local completion
    while IFS='' read -r completion; do
        COMPREPLY+=("${completion}")
    done < <(IFS=$'\n' compgen "${@}" -- "${cur}")
}

__wisp_custom_complete() {
    if [[ -n "${cur}" || -z ${COMP_WORDS[${COMP_CWORD}]} || "${COMP_LINE:${COMP_POINT}:1}" != ' ' ]]; then
        local -ar words=("${COMP_WORDS[@]}")
    else
        local -ar words=("${COMP_WORDS[@]::${COMP_CWORD}}" '' "${COMP_WORDS[@]:${COMP_CWORD}}")
    fi

    "${COMP_WORDS[0]}" "${@}" "${words[@]}"
}

_wisp() {
    local state
    state="$(shopt -p;shopt -po)"
    trap "${state//$'\n'/;}" RETURN
    shopt -s extglob
    set +o history +o posix

    local -xr SAP_SHELL=bash
    local -x SAP_SHELL_VERSION
    SAP_SHELL_VERSION="$(IFS='.';printf %s "${BASH_VERSINFO[*]}")"
    local -r SAP_SHELL_VERSION

    local -r cur="${2}"
    local -r prev="${3}"

    local -i positional_number
    local -a unparsed_words=("${COMP_WORDS[@]:1:${COMP_CWORD}}")

    local -a repeating_flags=()
    local -a non_repeating_flags=(--version -h --help)
    local -a repeating_options=()
    local -a non_repeating_options=()
    __wisp_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    respond|chat|tools|models|mcp|logs|config|doctor|approvals|facts|notify|scan|redact|watch|draft|classifier|completions|help)
        # Offer subcommand argument completions
        "_wisp_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'respond chat tools models mcp logs config doctor approvals facts notify scan redact watch draft classifier completions help' -- "${cur}"))
        ;;
    esac
}

_wisp_respond() {
    repeating_flags=()
    non_repeating_flags=(--no-tools --unsafe --stream --no-stream -y --yes --version -h --help)
    repeating_options=(--tool)
    non_repeating_options=(-i --instructions -m --model --schema)
    __wisp_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '-i'|'--instructions')
        return
        ;;
    '--tool')
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion respond -- --tool "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    '-m'|'--model')
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion respond -- --model "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    '--schema')
        return
        ;;
    esac
}

_wisp_chat() {
    repeating_flags=()
    non_repeating_flags=(--no-tools --unsafe -y --yes --list --json --plain --version -h --help)
    repeating_options=(--tool)
    non_repeating_options=(-i --instructions -m --model -r --resume --save)
    __wisp_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '-i'|'--instructions')
        return
        ;;
    '--tool')
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion chat -- --tool "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    '-m'|'--model')
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion chat -- --model "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    '-r'|'--resume')
        return
        ;;
    '--save')
        return
        ;;
    esac
}

_wisp_tools() {
    repeating_flags=()
    non_repeating_flags=(--json --markdown --version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_models() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    list|enable|disable|check|pull)
        # Offer subcommand argument completions
        "_wisp_models_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'list enable disable check pull' -- "${cur}"))
        ;;
    esac
}

_wisp_models_list() {
    repeating_flags=()
    non_repeating_flags=(--all --no-tools --json --version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_models_enable() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options -1

    # Offer positional completions
    case "${positional_number}" in
    *)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion models enable -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_models_disable() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options -1
}

_wisp_models_check() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options -1
}

_wisp_models_pull() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1
}

_wisp_mcp() {
    repeating_flags=()
    non_repeating_flags=(--no-tools --unsafe -y --yes --version -h --help)
    repeating_options=(--tool)
    non_repeating_options=(-i --instructions -m --model)
    __wisp_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '-i'|'--instructions')
        return
        ;;
    '--tool')
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion mcp -- --tool "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    '-m'|'--model')
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion mcp -- --model "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_logs() {
    repeating_flags=()
    non_repeating_flags=(--json -f --follow --version -h --help)
    repeating_options=(--kind)
    non_repeating_options=(--session --tool --last -l)
    __wisp_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--session')
        return
        ;;
    '--kind')
        return
        ;;
    '--tool')
        return
        ;;
    '--last'|'-l')
        return
        ;;
    esac
}

_wisp_config() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    show|list|get|set|unset)
        # Offer subcommand argument completions
        "_wisp_config_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'show list get set unset' -- "${cur}"))
        ;;
    esac
}

_wisp_config_show() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_config_list() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_config_get() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion config get -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_config_set() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options -1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion config set -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_config_unset() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion config unset -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_doctor() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_approvals() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    list|revoke|clear|pending|approve|deny)
        # Offer subcommand argument completions
        "_wisp_approvals_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'list revoke clear pending approve deny' -- "${cur}"))
        ;;
    esac
}

_wisp_approvals_list() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_approvals_revoke() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion approvals revoke -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_approvals_clear() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_approvals_pending() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_approvals_approve() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=(--scope)
    __wisp_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--scope')
        __wisp_add_completions -W 'once'$'\n''session'$'\n''project'$'\n''always'
        return
        ;;
    esac

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion approvals approve -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_approvals_deny() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion approvals deny -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_facts() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    pending|keep|drop)
        # Offer subcommand argument completions
        "_wisp_facts_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'pending keep drop' -- "${cur}"))
        ;;
    esac
}

_wisp_facts_pending() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_facts_keep() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion facts keep -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_facts_drop() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W "$(__wisp_custom_complete ---completion facts drop -- positional@0 "${COMP_CWORD}" "$(__wisp_cursor_index_in_current_word)")"
        return
        ;;
    esac
}

_wisp_notify() {
    repeating_flags=()
    non_repeating_flags=(--sound --version -h --help)
    repeating_options=()
    non_repeating_options=(-t --title --subtitle --route)
    __wisp_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '-t'|'--title')
        return
        ;;
    '--subtitle')
        return
        ;;
    '--route')
        return
        ;;
    esac
}

_wisp_scan() {
    repeating_flags=()
    non_repeating_flags=(--personal --thorough --json --version -h --help)
    repeating_options=()
    non_repeating_options=(-m --model)
    __wisp_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '-m'|'--model')
        return
        ;;
    esac
}

_wisp_redact() {
    repeating_flags=()
    non_repeating_flags=(--secrets-only --thorough --version -h --help)
    repeating_options=()
    non_repeating_options=(-m --model)
    __wisp_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '-m'|'--model')
        return
        ;;
    esac
}

_wisp_watch() {
    repeating_flags=()
    non_repeating_flags=(--no-files --no-triage -y --yes --version -h --help)
    repeating_options=(--path)
    non_repeating_options=(-C --directory --every --settle --notify --max-runs -m --model)
    __wisp_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '-C'|'--directory')
        return
        ;;
    '--path')
        return
        ;;
    '--every')
        return
        ;;
    '--settle')
        return
        ;;
    '--notify')
        __wisp_add_completions -W 'change'$'\n''failure'$'\n''always'$'\n''never'
        return
        ;;
    '--max-runs')
        return
        ;;
    '-m'|'--model')
        return
        ;;
    esac
}

_wisp_draft() {
    repeating_flags=()
    non_repeating_flags=(-y --yes --version -h --help)
    repeating_options=()
    non_repeating_options=(-m --model)
    __wisp_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '-m'|'--model')
        return
        ;;
    esac

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W 'commit'$'\n''pr'$'\n''changelog'
        return
        ;;
    esac
}

_wisp_classifier() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    list|train|measure|use|remove)
        # Offer subcommand argument completions
        "_wisp_classifier_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'list train measure use remove' -- "${cur}"))
        ;;
    esac
}

_wisp_classifier_list() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0
}

_wisp_classifier_train() {
    repeating_flags=()
    non_repeating_flags=(--from-audit --use --version -h --help)
    repeating_options=(--exclude)
    non_repeating_options=(--examples)
    __wisp_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--examples')
        return
        ;;
    '--exclude')
        return
        ;;
    esac
}

_wisp_classifier_measure() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=(--examples --classifier --coreml-model)
    __wisp_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--examples')
        return
        ;;
    '--classifier')
        __wisp_add_completions -W 'rules'$'\n''system-model'$'\n''coreml'
        return
        ;;
    '--coreml-model')
        return
        ;;
    esac
}

_wisp_classifier_use() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1
}

_wisp_classifier_remove() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1
}

_wisp_completions() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    print|install)
        # Offer subcommand argument completions
        "_wisp_completions_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'print install' -- "${cur}"))
        ;;
    esac
}

_wisp_completions_print() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W 'zsh'$'\n''bash'$'\n''fish'
        return
        ;;
    esac
}

_wisp_completions_install() {
    repeating_flags=()
    non_repeating_flags=(--print-path --version -h --help)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options 1

    # Offer positional completions
    case "${positional_number}" in
    1)
        __wisp_add_completions -W 'zsh'$'\n''bash'$'\n''fish'
        return
        ;;
    esac
}

_wisp_help() {
    repeating_flags=()
    non_repeating_flags=(--version)
    repeating_options=()
    non_repeating_options=()
    __wisp_offer_flags_options -1
}

complete -o filenames -F _wisp wisp
