#!/bin/bash
# ============================================================================
# CMDR :: lib/doctor.sh
# Tool health: which external tools do the stored commands need, and which are
# missing on this machine. Powers `cmdr --doctor` and the missing-tool summary
# printed after `cmdr --pack load`. Pairs with contrib/cmdr-install-tool.sh,
# which turns a missing tool into an install.
# Part of cmdr_functions.sh; relies on globals from cmdr.sh. Not run directly.
# ============================================================================

# Binaries that every command line is allowed to assume — shell builtins and
# baseline POSIX/coreutils present on any Linux/macOS. Never reported "missing".
_DOCTOR_IGNORE=" cd echo printf test true false : [ read set export sudo command env time nohup exec xargs tee cat sort uniq head tail cut tr sed awk grep wc ls cp mv rm mkdir touch chmod chown find xxd base64 date sleep kill jq curl wget "

# Extract the external binaries a shell command string invokes.
# Splits on | ; && || and strips sudo / env / VAR=val / `xargs -I{} <tool>`
# prefixes, taking the first real command word of each segment.
# LIMITATION: does not descend into $(...) / `...` command substitutions or
# `bash -c '...'` payloads — a tool used only inside those is not detected.
_doctor_extract_bins() {
    printf '%s\n' "$1" | sed -e 's/&&/\n/g' -e 's/||/\n/g' | tr '|;' '\n\n' \
    | while IFS= read -r seg; do
        # shellcheck disable=SC2086
        set -- $seg
        while [ "$#" -gt 0 ]; do
            case "$1" in
                sudo|command|env|time|nohup|exec) shift ;;
                *=*) shift ;;                 # leading VAR=val assignment
                xargs)                        # xargs [-I{} ...] <tool> ...
                    shift
                    while [ "$#" -gt 0 ]; do
                        case "$1" in -*) shift ;; *) break ;; esac
                    done
                    ;;
                *) printf '%s\n' "$1"; break ;;
            esac
        done
    done | sort -u
}

# True if the binary should be checked (i.e. not an ignored builtin/coreutil).
_doctor_checkable() {
    case "$_DOCTOR_IGNORE" in *" $1 "*) return 1 ;; *) return 0 ;; esac
}

# Given a JSON object {tag:{command,...}}, print unique checkable binaries.
_doctor_tools_from_json() {
    local bins b
    bins=$(jq -r '.[].command // empty' 2>/dev/null <<< "$1" \
        | while IFS= read -r cmd; do [ -n "$cmd" ] && _doctor_extract_bins "$cmd"; done)
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        _doctor_checkable "$b" && printf '%s\n' "$b"
    done <<< "$bins" | sort -u
}

# Print the missing-tool summary for a set of just-imported commands (JSON
# object). Called after `cmdr --pack load`. Silent when nothing is missing.
doctor_after_import() {
    local commands_json="$1" tools missing=""
    tools=$(_doctor_tools_from_json "$commands_json")
    [ -z "$tools" ] && return 0
    local b
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
    done <<< "$tools"
    [ -z "$missing" ] && return 0
    echo -e "${YELLOW}Missing tools for the imported commands:${NC}${missing}"
    if [ -x "$SCRIPT_DIR/contrib/cmdr-install-tool.sh" ]; then
        echo -e "  install them:  ${CYAN}cmdr-install-tool${missing}${NC}   (or --all-missing)"
    fi
}

# `cmdr --doctor [tag]` — report which tools the stored commands need and which
# are missing. With a tag, only that command; otherwise the whole store.
doctor_report() {
    local only_tag="${1:-}"
    local store commands_json
    store=$(get_effective_commands)

    if [ -n "$only_tag" ]; then
        local resolved
        resolved=$(resolve_tag_or_alias "$only_tag" <(printf '%s' "$store") 2>/dev/null)
        [ -z "$resolved" ] && resolved="$only_tag"
        commands_json=$(jq --arg t "$resolved" 'if has($t) then {($t): .[$t]} else {} end' <<< "$store")
        if [ "$(jq 'length' <<< "$commands_json")" -eq 0 ]; then
            echo -e "${RED}Error:${NC} Command '$only_tag' not found."
            return 1
        fi
    else
        commands_json="$store"
    fi

    if [ "${CMDR_JSON:-false}" = true ]; then
        _doctor_report_json "$commands_json"
        return 0
    fi

    local tools total=0 present=0 missing=0
    tools=$(_doctor_tools_from_json "$commands_json")
    if [ -z "$tools" ]; then
        echo -e "${YELLOW}No external tools referenced.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Tool health${NC}${only_tag:+ (command: $only_tag)}"
    echo ""
    printf "  ${CYAN}%-16s  %-9s  %s${NC}\n" "TOOL" "STATUS" "PATH"
    local b path status miss_list=""
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        total=$((total + 1))
        if path=$(command -v "$b" 2>/dev/null); then
            status="${GREEN}ok${NC}"; present=$((present + 1))
        else
            status="${RED}missing${NC}"; path="-"; missing=$((missing + 1))
            miss_list="$miss_list $b"
        fi
        printf "  %-16s  %-20b  %s\n" "$b" "$status" "$path"
    done <<< "$tools"

    echo ""
    echo -e "  ${total} tool(s): ${GREEN}${present} present${NC}, ${RED}${missing} missing${NC}."
    if [ -n "$miss_list" ]; then
        if [ -n "$only_tag" ]; then
            echo -e "  install:  ${CYAN}cmdr-install-tool --for ${only_tag}${NC}"
        else
            echo -e "  install:  ${CYAN}cmdr-install-tool --all-missing${NC}   (or per tool:${miss_list})"
        fi
        return 1     # non-zero exit when something is missing (scriptable)
    fi
    return 0
}

# JSON form: [{tool, present, path}]  (one object per referenced tool)
_doctor_report_json() {
    local tools b path
    tools=$(_doctor_tools_from_json "$1")
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        if path=$(command -v "$b" 2>/dev/null); then
            jq -n --arg t "$b" --arg p "$path" '{tool:$t, present:true,  path:$p}'
        else
            jq -n --arg t "$b" '{tool:$t, present:false, path:null}'
        fi
    done <<< "$tools" | jq -s '.'
}
