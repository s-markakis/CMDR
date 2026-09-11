#!/bin/bash
# ============================================================================
# CMDR :: lib/packs.sh
# Import/export, command packs, interactive mode
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 11: Import, Export & Command Packs
# Import/export JSON files, and load pre-built command packs from packs/.
# ----------------------------------------------------------------------------

# Export all commands to a JSON file.
extract_commands() {
    local output_file="$1"
    if [ -z "$output_file" ]; then
        echo -e "${RED}Error:${NC} Output file path required."
        exit 1
    fi

    if [ ! -s "$COMMANDS_FILE" ] || [ "$(jq 'length' "$COMMANDS_FILE")" -eq 0 ]; then
        echo -e "${YELLOW}No commands to extract.${NC}"
        return 0
    fi

    jq '.' "$COMMANDS_FILE" > "$output_file"
    log_event "INFO" "Extracted commands to: $output_file"
    echo -e "${GREEN}Commands extracted to:${NC} $output_file"
}

# Export the log file.
extract_logs() {
    local output_file="$1"
    if [ -z "$output_file" ]; then
        echo -e "${RED}Error:${NC} Output file path required."
        exit 1
    fi

    if [ ! -s "$LOG_FILE" ]; then
        echo -e "${YELLOW}Log file is empty.${NC}"
        return 0
    fi

    cp "$LOG_FILE" "$output_file"
    log_event "INFO" "Extracted logs to: $output_file"
    echo -e "${GREEN}Logs extracted to:${NC} $output_file"
}

# Import and merge commands from a JSON file. Single-pass validation with jq
# filters invalid tags and empty commands in one shot (O(1) jq calls).
install_commands() {
    local input_file="$1"
    if [ -z "$input_file" ] || [ ! -f "$input_file" ]; then
        echo -e "${RED}Error:${NC} Input file not provided or does not exist."
        exit 1
    fi

    if [ ! -s "$input_file" ]; then
        echo -e "${RED}Error:${NC} Input file is empty."
        exit 1
    fi

    if ! jq -e . "$input_file" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Input file is not valid JSON."
        exit 1
    fi

    # Single-pass: validate tags, filter empties, default categories
    local validated_json
    validated_json=$(jq '
        to_entries
        | map(select(
            (.key | test("^[a-zA-Z0-9_-]+$")) and
            ((.value.command // "") | length > 0)
        ))
        | map(.value.category //= "default")
        | from_entries
    ' "$input_file")

    local total imported skipped
    total=$(jq 'length' "$input_file")
    imported=$(echo "$validated_json" | jq 'length')
    skipped=$((total - imported))

    if [ "$imported" -eq 0 ]; then
        echo -e "${YELLOW}No valid commands to import.${NC}"
        return 0
    fi

    backup_commands "$WRITE_COMMANDS_FILE"

    local tmp_file
    tmp_file=$(_mktemp_beside "$WRITE_COMMANDS_FILE")
    if ! echo "$validated_json" | jq -s '.[0] * .[1]' "$WRITE_COMMANDS_FILE" - > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "Failed to merge commands"
        echo -e "${RED}Error:${NC} Failed to merge commands."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"

    # Enforce alias invariants on the merged store: an alias may not shadow any
    # tag, nor be shared by two commands. (Interactive `-a` validates this, but a
    # raw pack/import merge can introduce cross-pack collisions — e.g. one pack's
    # tag equal to another's alias.) Tags always win; for a shared alias the first
    # command (in store order) keeps it. Stripped aliases are reported.
    local norm_json stripped
    norm_json=$(jq '
        ([keys[]]) as $tags
        | reduce (to_entries[]) as $e ({out: {}, claimed: {}, stripped: []};
            (reduce ($e.value.aliases // [])[] as $a
                ({keep: [], claimed: .claimed, stripped: []};
                    if (($tags | index($a)) != null and $a != $e.key) then
                        .stripped += [$e.key + " → " + $a + " (tag exists)"]
                    elif (.claimed[$a] != null) then
                        .stripped += [$e.key + " → " + $a + " (used by " + .claimed[$a] + ")"]
                    else
                        .keep += [$a] | .claimed[$a] = $e.key
                    end
                )) as $r
            | .claimed = $r.claimed
            | .stripped += $r.stripped
            | .out[$e.key] = ($e.value
                | if ($r.keep | length) > 0 then .aliases = $r.keep else del(.aliases) end)
        )
    ' "$WRITE_COMMANDS_FILE" 2>/dev/null)
    stripped=$(printf '%s' "$norm_json" | jq -r '.stripped[]?' 2>/dev/null)
    if [ -n "$stripped" ]; then
        local tmp2
        tmp2=$(_mktemp_beside "$WRITE_COMMANDS_FILE")
        if printf '%s' "$norm_json" | jq '.out' > "$tmp2" 2>/dev/null; then
            mv "$tmp2" "$WRITE_COMMANDS_FILE"
            echo -e "${YELLOW}Note:${NC} stripped conflicting alias(es) to keep lookups unambiguous:"
            while IFS= read -r s; do
                [ -n "$s" ] && echo -e "  ${YELLOW}-${NC} $s"
            done <<< "$stripped"
            log_event "WARNING" "Stripped conflicting aliases on import from $input_file: $(printf '%s' "$stripped" | tr '\n' ';')"
        else
            rm -f "$tmp2"
        fi
    fi

    [ "$USE_LOCAL" = true ] && _retrust_local

    log_event "INFO" "Installed $imported commands from: $input_file ($skipped skipped)"
    echo -e "${GREEN}Imported $imported commands${NC} ($skipped skipped)."

    # Flag any external tools the imported commands need but this host lacks.
    doctor_after_import "$validated_json"
}

# List available command packs from the packs/ directory.
list_packs() {
    [ "${CMDR_JSON:-false}" = true ] && { json_packs; return 0; }
    if [ ! -d "$PACKS_DIR" ]; then
        echo -e "${YELLOW}No packs directory found.${NC}"
        return 0
    fi

    local found=false
    echo -e "${BOLD}${YELLOW}Available command packs:${NC}"
    echo ""

    for pack_file in "$PACKS_DIR"/*.json; do
        [ ! -f "$pack_file" ] && continue
        found=true
        local pack_name count categories
        pack_name=$(basename "$pack_file" .json)
        count=$(jq 'length' "$pack_file" 2>/dev/null || echo 0)
        categories=$(jq -r '[.[] | .category] | unique | join(", ")' "$pack_file" 2>/dev/null)
        printf "  ${CYAN}%-20s${NC}  %d commands  [%s]\n" "$pack_name" "$count" "$categories"
    done

    if [ "$found" = false ]; then
        echo -e "${YELLOW}No packs available.${NC}"
    fi
}

# Load a named pack by importing its JSON file.
load_pack() {
    local name="$1"
    local pack_file="$PACKS_DIR/${name}.json"

    if [ ! -f "$pack_file" ]; then
        echo -e "${RED}Error:${NC} Pack '$name' not found."
        echo -e "Run ${CYAN}cmdr --pack list${NC} to see available packs."
        exit 1
    fi

    echo -e "${GREEN}Loading pack:${NC} $name"
    install_commands "$pack_file"
}

# ----------------------------------------------------------------------------
# Section 12: Interactive Mode
# Menu-driven interface for browsing and running commands.
# ----------------------------------------------------------------------------

# `cmdr interactive` now enters the same hub as `cmdr -I` / `--menu`, so there
# is one interactive front-end (plus the fzf/bash picker) instead of three
# overlapping ones. The legacy category-browser was folded into interactive_menu.
interactive_mode() {
    interactive_menu
}

