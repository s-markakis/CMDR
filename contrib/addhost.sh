# shellcheck shell=sh
# ============================================================================
# CMDR :: contrib/addhost.sh
# ----------------------------------------------------------------------------
# A muscle-memory shim over `cmdr --host`. POSIX sh — source it from bash or
# zsh (Kali's default) in your shell rc:
#
#     . /path/to/CMDR/contrib/addhost.sh
#
# Then the classic one-liner works, and CMDR's host inventory + /etc/hosts
# stay in lockstep:
#
#     addhost $IP box.htb admin.box.htb      # add to inventory AND /etc/hosts
#     synchosts                              # re-push every workspace host
#     synchosts --clear                      # drop this workspace's block
#     delhost box                            # remove from inventory (+ hint)
#
# The real work (marker block, idempotent rewrite, sudo-only-when-needed,
# .cmdr.bak, DNS flush, collision reporting) lives in CMDR itself.
#
# If `cmdr` is not on PATH, set CMDR_BIN=/path/to/cmdr.sh before sourcing.
# ============================================================================

_addhost_cmdr() {
    if [ -n "${CMDR_BIN:-}" ]; then
        "$CMDR_BIN" "$@"
    elif command -v cmdr >/dev/null 2>&1; then
        cmdr "$@"
    else
        echo "addhost: 'cmdr' not on PATH — run CMDR's install.sh, or set CMDR_BIN=/path/to/cmdr.sh" >&2
        return 127
    fi
}

# addhost <ip> <hostname> [hostname ...]
addhost() {
    if [ "$#" -lt 2 ]; then
        echo "usage: addhost <ip> <hostname> [hostname ...]" >&2
        return 2
    fi
    _addhost_ip=$1
    shift
    _addhost_names=$*
    _addhost_first=${1%%.*}          # label before the first dot of the first name

    _addhost_cmdr --host add "$_addhost_ip" --name "$_addhost_first" \
        --hostname "$_addhost_names" --etc || return $?

    # Screenshot-style echo, one line per name (POSIX split via tr).
    printf '%s\n' "$_addhost_names" | tr ' ' '\n' | while IFS= read -r _addhost_n; do
        [ -n "$_addhost_n" ] && echo "Added/Updated: $_addhost_ip $_addhost_n"
    done
    unset _addhost_ip _addhost_names _addhost_first _addhost_n
}

# synchosts [--clear]  — re-mirror (or remove) the active workspace's block.
synchosts() {
    _addhost_cmdr --host sync-etc "$@"
}

# delhost <name>  — drop a host from the inventory. If a cmdr /etc/hosts block
# exists, re-mirror it so the removed host's line goes too (empty inventory
# clears the block). Pass --keep-etc to leave /etc/hosts untouched.
delhost() {
    _delhost_keep=0
    case "${1:-}" in --keep-etc) _delhost_keep=1; shift ;; esac
    if [ "$#" -lt 1 ]; then
        echo "usage: delhost [--keep-etc] <host-name>" >&2
        unset _delhost_keep
        return 2
    fi
    _addhost_cmdr --host rm "$1" || { unset _delhost_keep; return $?; }
    # Re-mirror /etc/hosts (may prompt for sudo) so the removed host's line goes.
    [ "$_delhost_keep" -eq 0 ] && _addhost_cmdr --host sync-etc
    unset _delhost_keep
}
