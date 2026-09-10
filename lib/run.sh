#!/bin/bash
# ============================================================================
# CMDR :: lib/run.sh
# Execution engine, hosts, run history
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 8: Execution Engine
# Run commands with env-var and placeholder substitution, timing, optional
# output capture (--save), dry-run, clipboard copy, and command chaining.
# ----------------------------------------------------------------------------

# Run a stored command by tag or alias. Supports host targeting (@name / --on /
# --all-hosts), output capture (--capture), danger confirmation, and history.
run_command() {
    local tag="$1"
    shift
    local run_args=("$@")

    notify_untrusted_local

    # History re-run: `cmdr -r !` or `cmdr -r last`
    if [ "$tag" = "!" ] || [ "$tag" = "last" ]; then
        rerun_last
        return $?
    fi

    tag=$(sanitize_tag "$tag") || exit 1

    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    local effective
    effective=$(get_effective_commands)

    local cmd danger
    cmd=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].command // empty')
    danger=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].danger // false')

    if [ -z "$cmd" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    # Pull any @host selector out of the positional args.
    local host_sel="" filtered_args=()
    local a
    for a in "${run_args[@]}"; do
        if [ "${a:0:1}" = "@" ]; then host_sel="${a:1}"; else filtered_args+=("$a"); fi
    done
    run_args=("${filtered_args[@]}")
    # --on implies a host target for SSH.
    [ -n "$CMDR_ON" ] && [ -z "$host_sel" ] && host_sel="$CMDR_ON"

    # Build the list of hosts to run against ("" = a single local, host-less run).
    local hosts=()
    if [ "$CMDR_ALL_HOSTS" = true ]; then
        local h
        while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done < <(list_host_names)
        if [ "${#hosts[@]}" -eq 0 ]; then
            echo -e "${RED}Error:${NC} No hosts defined. Add one with 'cmdr --host add'."
            exit 1
        fi
    elif [ -n "$host_sel" ]; then
        hosts=("$host_sel")
    else
        hosts=("")
    fi

    local overall=0
    local hcmd label rcmd st
    for h in "${hosts[@]}"; do
        hcmd="$cmd"
        label="$tag"
        if [ -n "$h" ]; then
            if ! _host_exists "$h"; then
                echo -e "${RED}Error:${NC} Unknown host '$h'."
                overall=1; continue
            fi
            hcmd=$(apply_host_vars "$hcmd" "$h")
            label="$tag@$h"
        fi
        if ! rcmd=$(resolve_command "$hcmd" "${run_args[@]}"); then
            overall=1; continue
        fi
        _run_one "$tag" "$label" "$rcmd" "$h" "$danger"
        st=$?
        [ "$st" -ne 0 ] && overall=$st
    done
    return $overall
}

# Execute a single fully-resolved invocation: danger gate, dry-run, local or
# remote (SSH) execution, output capture/save, timing, and history.
_run_one() {
    local tag="$1" label="$2" cmd="$3" host="$4" danger="$5"

    # Danger gate: always confirm, even under -y, unless dry-running.
    if [ "$danger" = "true" ] && [ "$DRY_RUN" != true ]; then
        echo -e "${RED}${BOLD}DANGER:${NC} $cmd"
        read -p "Run this command marked dangerous? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${YELLOW}Skipped '$label'.${NC}"
            return 0
        fi
    fi

    # Fill secret-backed {NAME} tokens only now, at exec time. `$cmd` keeps the
    # tokens so secrets never reach the screen, history, or logs.
    local exec_cmd
    exec_cmd=$(resolve_secrets "$cmd")

    # Wrap for remote execution when --on targets a host.
    if [ -n "$CMDR_ON" ] && [ -n "$host" ]; then
        if ! exec_cmd=$(build_ssh_cmd "$host" "$exec_cmd"); then
            return 1
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        # Show the display command (tokens, not secret values).
        local show="$cmd"
        [ -n "$CMDR_ON" ] && [ -n "$host" ] && show=$(build_ssh_cmd "$host" "$cmd")
        echo -e "${YELLOW}[DRY RUN]${NC} (${label}) Would execute: $show"
        log_event "INFO" "Dry run for '$label': $show"
        return 0
    fi

    echo -e "${GREEN}Running (${label}):${NC} $cmd"

    local start_time status output output_file=""
    start_time=$(date +%s)

    if [ -n "$CMDR_CAPTURE" ]; then
        # Capture stdout into a var (stderr still streams to the terminal).
        output=$(bash -c "$exec_cmd")
        status=$?
        printf '%s\n' "$output"
        if [ "$SAVE_OUTPUT" = true ]; then
            mkdir -p "$OUTPUTS_DIR"
            output_file="$OUTPUTS_DIR/${tag}_$(date +%Y%m%d_%H%M%S).log"
            printf '%s\n' "$output" > "$output_file"
        fi
        _capture_store "$output"
    elif [ "$SAVE_OUTPUT" = true ]; then
        mkdir -p "$OUTPUTS_DIR"
        output_file="$OUTPUTS_DIR/${tag}_$(date +%Y%m%d_%H%M%S).log"
        bash -c "$exec_cmd" 2>&1 | tee "$output_file"
        status=${PIPESTATUS[0]}
    else
        bash -c "$exec_cmd"
        status=$?
    fi

    local end_time elapsed duration
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    duration=$(format_duration "$elapsed")

    [ -n "$output_file" ] && echo -e "${CYAN}Output saved to:${NC} $output_file"
    echo -e "${CYAN}Completed in ${duration} (exit: $status)${NC}"
    record_history "$tag" "$cmd" "$host" "$status" "$duration"
    log_event "INFO" "Ran '$label': $cmd (exit: $status, ${duration})"
    return $status
}

# Store captured output into a workspace env var. CMDR_CAPTURE is "VAR" or
# "VAR:regex"; with a regex, the first match is stored, else the trimmed output.
_capture_store() {
    local output="$1"
    local var="${CMDR_CAPTURE%%:*}"
    local regex=""
    [ "$CMDR_CAPTURE" != "$var" ] && regex="${CMDR_CAPTURE#*:}"

    var=$(sanitize_tag "$var") || return 1

    local value
    if [ -n "$regex" ]; then
        value=$(printf '%s\n' "$output" | grep -oE "$regex" | head -1)
    else
        value=$(printf '%s' "$output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    # Serialize with any concurrent run/CRUD writing the same env store.
    with_store_lock _env_set_kv "$var" "$value"
    log_event "INFO" "Captured env var $var from '$tag'"
    echo -e "${GREEN}Captured${NC} {$var} = ${value}"
}

# Run multiple tagged commands in sequence. Stops on first failure.
chain_commands() {
    local tags=("$@")

    if [ "${#tags[@]}" -eq 0 ]; then
        echo -e "${RED}Error:${NC} No commands specified for chain."
        exit 1
    fi

    echo -e "${BOLD}${GREEN}Running chain:${NC} ${tags[*]}"
    echo ""

    local step=1
    for tag in "${tags[@]}"; do
        echo -e "${CYAN}[${step}/${#tags[@]}] Running: $tag${NC}"
        run_command "$tag"
        local status=$?
        if [ $status -ne 0 ] && [ "$DRY_RUN" != true ]; then
            echo -e "${RED}Chain stopped: '$tag' failed (exit: $status)${NC}"
            return $status
        fi
        ((step++))
        echo ""
    done

    echo -e "${GREEN}Chain completed successfully.${NC}"
}

# Copy the fully-resolved command to the system clipboard instead of running it.
clipboard_copy() {
    local tag="$1"
    shift
    local run_args=("$@")

    notify_untrusted_local
    tag=$(sanitize_tag "$tag") || exit 1

    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    local effective
    effective=$(get_effective_commands)

    local cmd
    cmd=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].command // empty')

    if [ -z "$cmd" ]; then
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    cmd=$(resolve_command "$cmd" "${run_args[@]}")
    # Clipboard contents are meant to be pasted and run, so fill secrets here.
    cmd=$(resolve_secrets "$cmd")

    # Try available clipboard tools in order of preference
    if command -v xclip >/dev/null 2>&1; then
        echo -n "$cmd" | xclip -selection clipboard
    elif command -v xsel >/dev/null 2>&1; then
        echo -n "$cmd" | xsel --clipboard --input
    elif command -v pbcopy >/dev/null 2>&1; then
        echo -n "$cmd" | pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then
        echo -n "$cmd" | wl-copy
    else
        echo -e "${YELLOW}No clipboard tool found.${NC} Command:"
        echo "$cmd"
        log_event "WARNING" "No clipboard tool available"
        return 1
    fi

    echo -e "${GREEN}Copied to clipboard:${NC} $cmd"
    log_event "INFO" "Copied command '$tag' to clipboard"
}

# ----------------------------------------------------------------------------
# Section 8b: Host / Target Model
# Per-workspace inventory of hosts. Commands reference {TARGET}/{RHOST}/{OS}/
# {RUSER}/{RPORT}; selecting a host (@name, --on, --all-hosts) fills them.
# ----------------------------------------------------------------------------

# True if a host with the given name exists.
_host_exists() {
    [ -f "$HOSTS_FILE" ] && jq -e --arg n "$1" 'has($n)' "$HOSTS_FILE" >/dev/null 2>&1
}

# Read a single field of a host (ip/hostname/os/user/port).
_host_get() {
    [ -f "$HOSTS_FILE" ] || return 1
    jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // empty' "$HOSTS_FILE" 2>/dev/null
}

# Print all host names, one per line.
list_host_names() {
    [ -f "$HOSTS_FILE" ] || return 0
    jq -r 'keys[]' "$HOSTS_FILE" 2>/dev/null
}

# Substitute host placeholders in a command for the named host.
apply_host_vars() {
    local cmd="$1" name="$2"
    local ip host os user port target
    ip=$(_host_get "$name" ip)
    host=$(_host_get "$name" hostname)
    os=$(_host_get "$name" os)
    user=$(_host_get "$name" user)
    port=$(_host_get "$name" port)
    # hostname may carry several space-separated names (all written to
    # /etc/hosts by --host sync-etc); the first is canonical for var fill / SSH.
    host="${host%% *}"
    target="${ip:-$host}"

    cmd="${cmd//\{TARGET\}/$target}"
    cmd="${cmd//\{RHOST\}/$target}"
    [ -n "$host" ] && cmd="${cmd//\{RHOSTNAME\}/$host}"
    [ -n "$os" ]   && cmd="${cmd//\{OS\}/$os}"
    [ -n "$user" ] && cmd="${cmd//\{RUSER\}/$user}"
    [ -n "$port" ] && cmd="${cmd//\{RPORT\}/$port}"
    echo "$cmd"
}

# Build an `ssh ...` command string (for bash -c) that runs cmd on a host.
build_ssh_cmd() {
    local host="$1" cmd="$2"
    local ip hostname user port target dest
    ip=$(_host_get "$host" ip)
    hostname=$(_host_get "$host" hostname)
    user=$(_host_get "$host" user)
    port=$(_host_get "$host" port)
    hostname="${hostname%% *}"          # first name only for the SSH destination
    target="${ip:-$hostname}"

    if [ -z "$target" ]; then
        echo -e "${RED}Error:${NC} Host '$host' has no ip/hostname for SSH." >&2
        return 1
    fi

    dest="$target"
    [ -n "$user" ] && dest="$user@$target"

    if [ -n "$port" ]; then
        printf 'ssh -p %q %q %q' "$port" "$dest" "$cmd"
    else
        printf 'ssh %q %q' "$dest" "$cmd"
    fi
}

# Add or update a host. IP is positional; name/os/user/port/hostname via flags.
host_add() {
    local ip="$1"
    if [ -z "$ip" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --host add <ip> --name <name> [--hostname h] [--os o] [--user u] [--port p]"
        exit 1
    fi

    if ! _etc_valid_ip "$ip"; then
        echo -e "${RED}Error:${NC} '$ip' is not a valid IPv4/IPv6 address." >&2
        exit 1
    fi

    local name="${CMDR_HOST_NAME:-$ip}"
    name=$(sanitize_tag "$name") || exit 1

    if [ -n "$CMDR_HOST_HOSTNAME" ] && ! _etc_valid_names "$CMDR_HOST_HOSTNAME"; then
        echo -e "${RED}Error:${NC} --hostname must be space-separated DNS names ([A-Za-z0-9.-])." >&2
        exit 1
    fi

    [ ! -f "$HOSTS_FILE" ] && echo "{}" > "$HOSTS_FILE"

    local entry
    entry=$(jq -n --arg ip "$ip" '{ip: $ip}')
    [ -n "$CMDR_HOST_HOSTNAME" ] && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_HOSTNAME" '. + {hostname: $v}')
    [ -n "$CMDR_HOST_OS" ]       && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_OS" '. + {os: $v}')
    [ -n "$CMDR_HOST_USER" ]     && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_USER" '. + {user: $v}')
    [ -n "$CMDR_HOST_PORT" ]     && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_PORT" '. + {port: $v}')

    local tmp_file
    tmp_file=$(_mktemp_beside "$HOSTS_FILE")
    jq --arg n "$name" --argjson e "$entry" '. + {($n): $e}' "$HOSTS_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$HOSTS_FILE"

    log_event "INFO" "Host added: $name ($ip)"
    echo -e "${GREEN}Host added:${NC} $name ($ip)"

    # Surface any hand-added /etc/hosts entry for these names. When --etc is set
    # the sync below prints this itself, so only do it here for the plain add.
    [ -n "$CMDR_HOST_HOSTNAME" ] && [ "${CMDR_HOST_ETC:-false}" != true ] \
        && _etc_hosts_report_existing "$CMDR_HOST_HOSTNAME"

    if [ "${CMDR_HOST_ETC:-false}" = true ]; then
        if [ -z "$CMDR_HOST_HOSTNAME" ]; then
            echo -e "${YELLOW}Note:${NC} --etc ignored — host has no --hostname to write to /etc/hosts."
        else
            etc_hosts_sync
        fi
    fi
}

# List all hosts in the active workspace.
host_list() {
    [ "${CMDR_JSON:-false}" = true ] && { json_hosts; return 0; }
    if [ ! -f "$HOSTS_FILE" ] || [ "$(jq 'length' "$HOSTS_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No hosts defined.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Hosts:${NC}"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}"
    fi
    echo ""
    printf "  ${CYAN}%-14s  %-15s  %-24s  %-8s  %-9s  %s${NC}\n" "NAME" "IP" "HOSTNAME" "OS" "USER" "HOSTS"
    # Use ASCII Unit Separator (0x1f) so empty middle fields aren't collapsed
    # by read's IFS-whitespace merging.
    jq -r 'to_entries[] | [.key, (.value.ip//""), (.value.hostname//""), (.value.os//""), (.value.user//"")] | join("\u001f")' "$HOSTS_FILE" \
        | while IFS=$'\037' read -r name ip hn os user; do
            mark=""
            _etc_hosts_has "$ip" "${hn%% *}" && mark="in /etc/hosts"
            printf "  %-14s  %-15s  %-24s  %-8s  %-9s  %s\n" "$name" "$ip" "$hn" "$os" "$user" "$mark"
        done
}

# Remove a host by name.
host_rm() {
    local name="$1"
    if [ -z "$name" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --host rm <name>"
        exit 1
    fi
    if ! _host_exists "$name"; then
        echo -e "${YELLOW}Host '$name' not found.${NC}"
        return 0
    fi
    local tmp_file
    tmp_file=$(_mktemp_beside "$HOSTS_FILE")
    jq --arg n "$name" 'del(.[$n])' "$HOSTS_FILE" > "$tmp_file" && mv "$tmp_file" "$HOSTS_FILE"
    log_event "INFO" "Host removed: $name"
    echo -e "${GREEN}Host removed:${NC} $name"

    if _etc_hosts_block_present; then
        echo -e "${YELLOW}Note:${NC} run 'cmdr --host sync-etc' to drop it from /etc/hosts too."
    fi
}

# ----------------------------------------------------------------------------
# Section 8b-2: /etc/hosts synchronisation
# Mirror the workspace's hosts (those with a --hostname) into a managed,
# per-workspace block in /etc/hosts, so `box.htb` resolves without hand-editing
# the file. The block is delimited by markers and rewritten wholesale on every
# sync, so entries never accumulate or duplicate. Everything outside the block
# is preserved byte-for-byte. CMDR_ETC_HOSTS overrides the target path (tests,
# or a non-root workflow pointing at a user-writable file).
# ----------------------------------------------------------------------------

_etc_hosts_file()  { echo "${CMDR_ETC_HOSTS:-/etc/hosts}"; }
_etc_block_begin() { echo "# >>> cmdr:${ACTIVE_WORKSPACE} >>>"; }
_etc_block_end()   { echo "# <<< cmdr:${ACTIVE_WORKSPACE} <<<"; }

# Loose IPv4/IPv6 validation — enough to keep junk out of a system file.
_etc_valid_ip() {
    local ip="$1" o
    if printf '%s\n' "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        local IFS=.
        for o in $ip; do
            [ "$o" -le 255 ] 2>/dev/null || return 1
        done
        return 0
    fi
    # IPv6: hex groups separated by colons, at least one colon pair.
    printf '%s\n' "$ip" | grep -qE '^[0-9A-Fa-f:]+:[0-9A-Fa-f:.]*$'
}

# One or more space-separated DNS-ish names, each [A-Za-z0-9.-].
_etc_valid_names() {
    local n
    local -a toks
    read -ra toks <<< "$1"
    [ "${#toks[@]}" -gt 0 ] || return 1
    for n in "${toks[@]}"; do
        printf '%s\n' "$n" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || return 1
    done
    return 0
}

# True if this workspace's managed block exists in the target file.
_etc_hosts_block_present() {
    local f
    f=$(_etc_hosts_file)
    [ -f "$f" ] && grep -qF "$(_etc_block_begin)" "$f"
}

# Print "<ip>\t<cmdr|manual>" for every /etc/hosts line that maps <name>.
# "cmdr" = inside this workspace's block, "manual" = anywhere else.
_etc_hosts_lookup() {
    local name="$1" f begin end line in_block=0 rc=1
    [ -n "$name" ] || return 1
    f=$(_etc_hosts_file)
    [ -f "$f" ] || return 1
    begin=$(_etc_block_begin)
    end=$(_etc_block_end)
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$begin") in_block=1; continue ;;
            "$end")   in_block=0; continue ;;
            '#'*|'')  continue ;;
        esac
        line="${line%%#*}"
        local -a parts
        read -ra parts <<< "$line"
        [ "${#parts[@]}" -ge 2 ] || continue
        local i
        for (( i=1; i<${#parts[@]}; i++ )); do
            [ "${parts[$i]}" = "$name" ] || continue
            if [ "$in_block" = 1 ]; then printf '%s\tcmdr\n' "${parts[0]}"
            else printf '%s\tmanual\n' "${parts[0]}"; fi
            rc=0
        done
    done < "$f"
    return $rc
}

# True if <name> currently resolves to <ip> anywhere in the target file.
_etc_hosts_has() {
    local ip="$1" name="$2"
    [ -n "$name" ] || return 1
    _etc_hosts_lookup "$name" 2>/dev/null | cut -f1 | grep -qxF "$ip"
}

# Show pre-existing /etc/hosts entries for the given names that CMDR will NOT
# touch — i.e. lines outside this workspace's managed block (hand-added, or
# another workspace's block). Returns 0 if it printed anything.
_etc_hosts_report_existing() {
    local n ip src rc=1
    local -a want
    read -ra want <<< "$1"
    for n in "${want[@]}"; do
        while IFS=$'\t' read -r ip src; do
            [ -n "$ip" ] || continue
            [ "$src" = manual ] || continue      # our own block is about to be rewritten
            echo -e "  ${YELLOW}already in ${NC}$(_etc_hosts_file)${YELLOW} (kept as-is):${NC} ${ip}  ${n}"
            rc=0
        done <<< "$(_etc_hosts_lookup "$n" 2>/dev/null)"
    done
    return $rc
}

# Emit the block body ("<ip>\t<names>" per line) from the host inventory.
_etc_hosts_block_body() {
    [ -f "$HOSTS_FILE" ] || return 0
    jq -r '
        to_entries[]
        | select((.value.hostname // "") != "")
        | "\(.value.ip // "")\(.value.hostname)"
    ' "$HOSTS_FILE" 2>/dev/null \
    | while IFS=$'\037' read -r ip names; do
        [ -n "$ip" ] || continue
        printf '%s\t%s\n' "$ip" "$names"
    done
}

# Copy $1 over $2, escalating with sudo only if needed, keeping one backup.
_etc_hosts_install() {
    local src="$1" dst="$2" need_sudo=""
    if [ -w "$dst" ] || { [ ! -e "$dst" ] && [ -w "$(dirname "$dst")" ]; }; then
        need_sudo=""
    elif command -v sudo >/dev/null 2>&1; then
        need_sudo=1
        echo -e "${YELLOW}Writing $dst needs root — you may be prompted for a password.${NC}"
    else
        echo -e "${RED}Error:${NC} $dst is not writable and 'sudo' is unavailable." >&2
        rm -f "$src"
        return 1
    fi

    if [ -f "$dst" ] && [ ! -f "${dst}.cmdr.bak" ]; then
        if [ -n "$need_sudo" ]; then sudo cp -p "$dst" "${dst}.cmdr.bak"
        else cp -p "$dst" "${dst}.cmdr.bak"; fi 2>/dev/null \
            && echo "  backup: ${dst}.cmdr.bak"
    fi

    if { [ -n "$need_sudo" ] && sudo cp "$src" "$dst"; } || \
       { [ -z "$need_sudo" ] && cp "$src" "$dst"; }; then
        rm -f "$src"
        _etc_hosts_flush_dns "$need_sudo"
        return 0
    fi
    echo -e "${RED}Error:${NC} failed to write $dst" >&2
    rm -f "$src"
    return 1
}

# Best-effort DNS cache flush (macOS only; silent no-op elsewhere).
_etc_hosts_flush_dns() {
    [ "$(uname -s)" = Darwin ] || return 0
    if [ -n "$1" ]; then
        sudo dscacheutil -flushcache 2>/dev/null
        sudo killall -HUP mDNSResponder 2>/dev/null
    else
        dscacheutil -flushcache 2>/dev/null
        killall -HUP mDNSResponder 2>/dev/null
    fi
    return 0
}

# Rewrite this workspace's block in /etc/hosts from the host inventory.
# `--clear` (or CMDR_ETC_CLEAR=true) removes the block instead.
etc_hosts_sync() {
    local clear=false
    { [ "${1:-}" = "--clear" ] || [ "${CMDR_ETC_CLEAR:-false}" = true ]; } && clear=true

    local f begin end body="" outside
    f=$(_etc_hosts_file)
    begin=$(_etc_block_begin)
    end=$(_etc_block_end)

    [ "$clear" = false ] && body=$(_etc_hosts_block_body)

    if [ "$clear" = false ] && [ -z "$body" ]; then
        echo -e "${YELLOW}No hosts with a --hostname in workspace '${ACTIVE_WORKSPACE}'.${NC}"
        echo    "Add one:  cmdr --host add <ip> --name <n> --hostname <fqdn> --etc"
        return 0
    fi

    if [ "$clear" = true ] && ! _etc_hosts_block_present; then
        echo -e "${YELLOW}No cmdr block for workspace '${ACTIVE_WORKSPACE}' in ${f}.${NC}"
        return 0
    fi

    # Everything outside our block (command substitution strips trailing blanks).
    outside=""
    if [ -f "$f" ]; then
        outside=$(awk -v b="$begin" -v e="$end" '
            $0==b { inb=1; next }
            $0==e { inb=0; next }
            !inb  { print }
        ' "$f")
    fi

    # Report collisions before we touch anything.
    if [ "$clear" = false ]; then
        local allnames
        allnames=$(printf '%s\n' "$body" | cut -f2- | tr '\n' ' ')
        _etc_hosts_report_existing "$allnames"
    fi

    local work
    work=$(_mktemp_beside "$f" 2>/dev/null) || work=$(mktemp "${TMPDIR:-/tmp}/cmdr_hosts.XXXXXX") || {
        echo -e "${RED}Error:${NC} could not create a temp file." >&2
        return 1
    }
    {
        [ -n "$outside" ] && printf '%s\n' "$outside"
        if [ "$clear" = false ]; then
            printf '%s\n' "$begin"
            printf '%s\n' "# managed by 'cmdr --host sync-etc' — lines between the markers are overwritten"
            printf '%s\n' "$body"
            printf '%s\n' "$end"
        fi
    } > "$work"

    if [ -f "$f" ] && cmp -s "$work" "$f"; then
        rm -f "$work"
        echo -e "${GREEN}/etc/hosts already current${NC} (workspace '${ACTIVE_WORKSPACE}')."
        return 0
    fi

    if _etc_hosts_install "$work" "$f"; then
        if [ "$clear" = true ]; then
            echo -e "${GREEN}Removed${NC} the cmdr block for '${ACTIVE_WORKSPACE}' from ${f}."
        else
            echo -e "${GREEN}Synced${NC} $(printf '%s\n' "$body" | grep -c .) host line(s) to ${f}:"
            printf '%s\n' "$body" | while IFS=$'\t' read -r ip names; do
                echo "    ${ip}    ${names}"
            done
        fi
        log_event "INFO" "etc-hosts sync (workspace=$ACTIVE_WORKSPACE clear=$clear)"
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
# Section 8c: Run History
# Append-only (capped) log of executed commands. Enables review and re-run.
# ----------------------------------------------------------------------------

# Record one run. Capped to the last $HISTORY_MAX entries.
_record_history_write() {
    local ts="$1" tag="$2" cmd="$3" host="$4" status="$5" duration="$6"
    [ ! -f "$HISTORY_FILE" ] && echo "[]" > "$HISTORY_FILE"
    local tmp_file
    tmp_file=$(_mktemp_beside "$HISTORY_FILE")
    jq --arg ts "$ts" --arg tag "$tag" --arg cmd "$cmd" --arg host "$host" \
       --arg st "$status" --arg dur "$duration" --argjson max "$HISTORY_MAX" \
       '. + [{timestamp:$ts, tag:$tag, command:$cmd, host:$host, exit:($st|tonumber), duration:$dur}] | .[-$max:]' \
       "$HISTORY_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$HISTORY_FILE"
}

record_history() {
    local tag="$1" cmd="$2" host="$3" status="$4" duration="$5"
    local ts
    ts=$(date +"%Y-%m-%d %T")
    # Serialize with any concurrent run so two histories don't clobber each other.
    with_store_lock _record_history_write "$ts" "$tag" "$cmd" "$host" "$status" "$duration"
}

# Show recent history (default 20 entries, newest first).
show_history() {
    [ "${CMDR_JSON:-false}" = true ] && { json_history; return 0; }
    local count="${1:-20}"
    if [ ! -f "$HISTORY_FILE" ] || [ "$(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No run history.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Run history (last $count):${NC}"
    echo ""
    jq -r --argjson n "$count" '.[-$n:] | reverse | .[]
        | [.timestamp, (.exit|tostring), .tag, (.host // ""), .command] | join("\u001f")' "$HISTORY_FILE" \
        | while IFS=$'\037' read -r ts ex tag host cmd; do
            local mark="${GREEN}ok${NC}"
            [ "$ex" != "0" ] && mark="${RED}$ex${NC}"
            local label="$tag"
            [ -n "$host" ] && label="$tag@$host"
            printf "  ${CYAN}%s${NC}  [%b]  %-18s  %s\n" "$ts" "$mark" "$label" "$cmd"
        done
}

# Re-run the most recent history entry (by tag, re-resolving env/host).
rerun_last() {
    if [ ! -f "$HISTORY_FILE" ] || [ "$(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${RED}Error:${NC} No run history."
        exit 1
    fi
    local last_tag last_host
    last_tag=$(jq -r '.[-1].tag // empty' "$HISTORY_FILE")
    last_host=$(jq -r '.[-1].host // empty' "$HISTORY_FILE")
    if [ -z "$last_tag" ]; then
        echo -e "${RED}Error:${NC} No run history."
        exit 1
    fi
    echo -e "${CYAN}Re-running:${NC} $last_tag${last_host:+ @$last_host}"
    if [ -n "$last_host" ]; then
        run_command "$last_tag" "@$last_host"
    else
        run_command "$last_tag"
    fi
}

