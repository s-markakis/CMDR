#!/usr/bin/env bash
# ============================================================================
# cmdr-install-tool — install the external tool(s) a CMDR command needs
# ----------------------------------------------------------------------------
# CMDR stores commands; it does not install their tools. When `cmdr -r <tag>`
# fails with "command not found", this resolves the missing binary against a
# recipe registry (contrib/tool-recipes.tsv) and installs it with the best
# method available on this platform (macOS: brew > go > pipx; Linux: apt > go
# > pipx).
#
# Fail-closed: it prints a PLAN and installs nothing unless you pass -y (or
# confirm interactively). Unknown/unresolvable tools are reported, never
# guessed at.
#
#   cmdr-install-tool <binary> ...     install these binaries if missing
#   cmdr-install-tool --for <tag>      install tools used by CMDR command <tag>
#   cmdr-install-tool --all-missing    scan the whole CMDR store, install gaps
#   cmdr-install-tool --list           print the recipe registry
#
# Options: -n/--dry-run  -y/--yes  --method brew|go|pipx|apt  --recipes FILE
#          --cmdr PATH    -h/--help
# ============================================================================
set -u

# --- resolve own dir (follow symlinks) so the recipes file is found next to us
SELF="${BASH_SOURCE[0]}"
while [ -h "$SELF" ]; do
    d="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)"
    SELF="$(readlink "$SELF")"; [[ "$SELF" != /* ]] && SELF="$d/$SELF"
done
SELF_DIR="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)"

RECIPES="$SELF_DIR/tool-recipes.tsv"
CMDR_BIN="${CMDR_BIN:-}"
DRY_RUN=false
ASSUME_YES=false
FORCE_METHOD=""

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "${RED}Error:${NC} $*" >&2; }

usage() { sed -n '2,40p' "$SELF"; }

# --- platform + toolchain detection --------------------------------------
OS="$(uname -s)"
have() { command -v "$1" >/dev/null 2>&1; }
# per-OS method preference order
if [ "$OS" = "Darwin" ]; then PREF=(brew go pipx); else PREF=(apt go pipx brew); fi

resolve_cmdr() {
    [ -n "$CMDR_BIN" ] && { echo "$CMDR_BIN"; return; }
    have cmdr && { command -v cmdr; return; }
    [ -x "$SELF_DIR/../cmdr.sh" ] && { echo "$SELF_DIR/../cmdr.sh"; return; }
    echo ""
}

# --- recipe lookup: prints "brew<TAB>go<TAB>pipx<TAB>apt" for a binary -----
recipe_for() {
    awk -F '\t' -v b="$1" '
        /^[[:space:]]*#/ {next} NF<5 {next}
        $1==b { printf "%s\t%s\t%s\t%s", $2,$3,$4,$5; found=1; exit }
        END { if(!found) exit 1 }
    ' "$RECIPES"
}

# note (col 6) for a binary, if any — shown as a post-install hint.
note_for() {
    awk -F '\t' -v b="$1" '
        /^[[:space:]]*#/ {next} NF<6 {next}
        $1==b { print $6; exit }
    ' "$RECIPES"
}

# choose a method for a binary given its recipe fields; echoes "method<TAB>cmd"
plan_method() {
    local bin="$1" brew_f="$2" go_m="$3" pipx_p="$4" apt_p="$5"
    local order=("${PREF[@]}")
    [ -n "$FORCE_METHOD" ] && order=("$FORCE_METHOD")
    local m
    for m in "${order[@]}"; do
        case "$m" in
            brew) [ "$brew_f" != "-" ] && have brew && { echo "brew	brew install $brew_f"; return 0; } ;;
            go)   [ "$go_m"  != "-" ] && have go   && { echo "go	go install $go_m"; return 0; } ;;
            pipx) [ "$pipx_p" != "-" ] && have pipx && { echo "pipx	pipx install $pipx_p"; return 0; } ;;
            apt)  [ "$apt_p" != "-" ] && have apt-get && { echo "apt	sudo apt-get install -y $apt_p"; return 0; } ;;
        esac
    done
    return 1
}

# --- extract invoked binaries from a shell command string -----------------
# Splits on | ; && || and strips sudo / command / env / VAR=val / xargs[-flags]
# prefixes, taking the first real command word of each segment.
# LIMITATION: does not descend into $(...) / `...` command substitutions or a
# `bash -c '...'` payload — a tool used only inside those is not detected.
extract_bins() {
    printf '%s\n' "$1" | sed -e 's/&&/\n/g' -e 's/||/\n/g' | tr '|;' '\n\n' \
    | while IFS= read -r seg; do
        # shellcheck disable=SC2086
        set -- $seg
        while [ "$#" -gt 0 ]; do
            case "$1" in
                sudo|command|env|time|nohup|exec) shift ;;
                *=*) shift ;;
                xargs) shift; while [ "$#" -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done ;;
                *) printf '%s\n' "$1"; break ;;
            esac
        done
    done | sort -u
}

# --- gather the target binary set based on mode ---------------------------
store_json() {
    local c; c="$(resolve_cmdr)"
    [ -z "$c" ] && { err "cmdr not found (set CMDR_BIN=/path/to/cmdr.sh)"; exit 2; }
    "$c" -s --json 2>/dev/null
}

bins_for_tag() {
    local tag="$1" cmd
    cmd="$(store_json | jq -r --arg t "$tag" '.[$t].command // empty')"
    [ -z "$cmd" ] && { err "no CMDR command tagged '$tag' in the active workspace"; exit 2; }
    extract_bins "$cmd"
}

bins_all_missing() {
    store_json | jq -r '.[].command' | while IFS= read -r cmd; do
        [ -n "$cmd" ] && extract_bins "$cmd"
    done | sort -u
}

# --- argument parsing -----------------------------------------------------
MODE="args"; TAG=""; declare -a WANT=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --for)         MODE="for"; TAG="${2:-}"; shift 2 ;;
        --all-missing) MODE="all"; shift ;;
        --list)        MODE="list"; shift ;;
        -n|--dry-run)  DRY_RUN=true; shift ;;
        -y|--yes)      ASSUME_YES=true; shift ;;
        --method)      FORCE_METHOD="${2:-}"; shift 2 ;;
        --recipes)     RECIPES="${2:-}"; shift 2 ;;
        --cmdr)        CMDR_BIN="${2:-}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            err "unknown option: $1"; usage; exit 2 ;;
        *)             WANT+=("$1"); shift ;;
    esac
done

[ -f "$RECIPES" ] || { err "recipe file not found: $RECIPES"; exit 2; }

if [ "$MODE" = "list" ]; then
    printf '%s%-14s %-16s %-8s %-10s %s%s\n' "$BOLD" "BINARY" "brew" "go" "pipx/apt" "note" "$NC"
    awk -F '\t' '/^[[:space:]]*#/||NF<6{next}{printf "%-14s %-16s %-8s %-10s %s\n",$1,$2,($3=="-"?"-":"go"),($4!="-"?$4:$5),$6}' "$RECIPES"
    exit 0
fi

# Read a newline list into WANT (bash 3.2 has no `mapfile`; macOS /bin/bash is 3.2).
_read_into_want() {
    WANT=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && WANT+=("$line")
    done
}

case "$MODE" in
    for)  [ -n "$TAG" ] || { err "--for needs a <tag>"; exit 2; }
          _read_into_want < <(bins_for_tag "$TAG") ;;
    all)  _read_into_want < <(bins_all_missing) ;;
    args) [ "${#WANT[@]}" -gt 0 ] || { usage; exit 2; } ;;
esac

# --- build the plan -------------------------------------------------------
declare -a TO_INSTALL_BIN=() TO_INSTALL_CMD=() TO_INSTALL_M=()
declare -a PRESENT=() UNRESOLVED=()
for bin in "${WANT[@]}"; do
    [ -z "$bin" ] && continue
    if have "$bin"; then PRESENT+=("$bin"); continue; fi
    if r="$(recipe_for "$bin" 2>/dev/null)"; then
        IFS=$'\t' read -r bf gm pp ap <<< "$r"
        if pm="$(plan_method "$bin" "$bf" "$gm" "$pp" "$ap")"; then
            IFS=$'\t' read -r method cmd <<< "$pm"
            TO_INSTALL_BIN+=("$bin"); TO_INSTALL_CMD+=("$cmd"); TO_INSTALL_M+=("$method")
            continue
        fi
    fi
    UNRESOLVED+=("$bin")
done

# --- print the plan -------------------------------------------------------
say "${BOLD}${CYAN}Tool install plan${NC}"
if [ "${#PRESENT[@]}" -gt 0 ]; then
    say "  ${GREEN}already installed:${NC} ${PRESENT[*]}"
fi
if [ "${#TO_INSTALL_BIN[@]}" -gt 0 ]; then
    say "  ${YELLOW}to install:${NC}"
    for i in "${!TO_INSTALL_BIN[@]}"; do
        printf '    %-14s [%s]  %s\n' "${TO_INSTALL_BIN[$i]}" "${TO_INSTALL_M[$i]}" "${TO_INSTALL_CMD[$i]}"
    done
fi
if [ "${#UNRESOLVED[@]}" -gt 0 ]; then
    say "  ${RED}no recipe / no usable toolchain:${NC} ${UNRESOLVED[*]}"
    say "    (add a row to $(basename "$RECIPES"), or install the toolchain)"
fi

[ "${#TO_INSTALL_BIN[@]}" -eq 0 ] && { say "Nothing to install."; [ "${#UNRESOLVED[@]}" -gt 0 ] && exit 1; exit 0; }

# go-bin PATH sanity check
for m in "${TO_INSTALL_M[@]}"; do
    if [ "$m" = go ]; then
        gobin="${GOBIN:-$(go env GOPATH 2>/dev/null)/bin}"
        case ":$PATH:" in *":$gobin:"*) ;; *)
            say "  ${YELLOW}note:${NC} go installs land in ${gobin} — add it to PATH to run them." ;;
        esac
        break
    fi
done

if [ "$DRY_RUN" = true ]; then say "${CYAN}(dry-run — nothing installed)${NC}"; exit 0; fi

if [ "$ASSUME_YES" != true ]; then
    printf '%s' "Proceed with the installs above? (y/N): "
    read -r ans </dev/tty || ans=""
    case "$ans" in y|Y) ;; *) say "Aborted."; exit 0 ;; esac
fi

# --- execute --------------------------------------------------------------
fails=0
for i in "${!TO_INSTALL_BIN[@]}"; do
    bin="${TO_INSTALL_BIN[$i]}"; cmd="${TO_INSTALL_CMD[$i]}"
    say "${CYAN}==>${NC} $cmd"
    if eval "$cmd"; then
        if command -v "$bin" >/dev/null 2>&1 || { [ "${TO_INSTALL_M[$i]}" = go ] && [ -x "${GOBIN:-$(go env GOPATH)/bin}/$bin" ]; }; then
            say "  ${GREEN}ok:${NC} $bin installed"
        else
            say "  ${YELLOW}installed but '$bin' still not on PATH${NC} (check PATH / shell rehash)"
        fi
        n="$(note_for "$bin")"
        [ -n "$n" ] && say "  ${YELLOW}note:${NC} $n"
    else
        say "  ${RED}failed:${NC} $bin"; fails=$((fails+1))
    fi
done

if [ "$fails" -gt 0 ]; then say "${RED}$fails install(s) failed.${NC}"; exit 1; fi
say "${GREEN}Done.${NC} Run 'hash -r' (or open a new shell) so your shell sees the new binaries."
exit 0
