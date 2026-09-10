# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`/etc/hosts` sync for the host model**: `cmdr --host sync-etc` mirrors every
  workspace host that has a `--hostname` into a managed, per-workspace block in
  `/etc/hosts` (`# >>> cmdr:<workspace> >>>` … `# <<< cmdr:<workspace> <<<`).
  The block is rewritten wholesale on each run, so entries never duplicate or
  accumulate; everything outside the block is preserved byte-for-byte.
  `--host sync-etc --clear` removes the block; `--host rm` prints a hint.
- **`--etc` on `cmdr --host add`**: adds the host and runs the sync in one step.
- **`--hostname` accepts multiple names**: space-separated; the first is
  canonical for `{RHOSTNAME}` / SSH, all of them are written to `/etc/hosts`.
- Writing `/etc/hosts` escalates with `sudo` only when the file is not already
  writable and only when the content actually changes, keeps a one-time
  `/etc/hosts.cmdr.bak`, and flushes the DNS cache on macOS. Pre-existing
  hand-added entries for a managed name are reported and left untouched.
  `$CMDR_ETC_HOSTS` overrides the target path.
- `cmdr --host list` marks which hosts are currently in `/etc/hosts`.
- **`contrib/addhost.sh`**: POSIX `addhost` / `synchosts` / `delhost` shell
  shims (source from bash or zsh) for the classic `addhost $IP box.htb` flow.
  `install.sh` offers to enable them (opt-in prompt), alongside the existing
  Linux (apt/dnf/yum/pacman) and macOS (brew) dependency handling.
- **`contrib/cmdr-install-tool.sh` + `contrib/tool-recipes.tsv`**: install the
  external tool a stored command needs when it's missing. Resolves a binary to
  a per-platform recipe (macOS `brew` > `go` > `pipx`; Linux `apt` > `go` >
  `pipx`) and installs it — fail-closed (prints a plan, installs only on `-y`
  or confirm). Modes: named binaries, `--for <tag>` (tools used by one command,
  parsed out of pipelines), `--all-missing` (scan the whole store), `--list`,
  `--dry-run`. Reads the store via `cmdr -s --json`; extend by adding a TSV row.
  Surfaces per-recipe notes (e.g. naabu/libpcap, masscan/root) after install.
  `install.sh` now also exposes it on `PATH` (symlink/alias) so the tip runs.
- **`cmdr --doctor [tag]`**: report which external tools the stored commands
  invoke and which are missing on this host (whole store, or one command).
  Exits non-zero when anything is missing, prints the exact `cmdr-install-tool`
  line, and has a `--json` form (`[{tool, present, path}]`). Baseline
  shell/coreutils/curl/jq are not reported. `cmdr --pack load` prints the same
  missing-tool summary right after importing a pack.

### Changed
- **`--host sync-etc` on an empty inventory now clears the block**: removing the
  last host with a `--hostname` and re-syncing tidies the managed `/etc/hosts`
  block away, instead of leaving it stale (mirror semantics: nothing in →
  nothing out). The `delhost` shim re-syncs after removal (`--keep-etc` opts out).
- **CI shellcheck now covers `contrib/*.sh`**, and the test suite gains sections
  for `--doctor`, `cmdr-install-tool` (plan logic), the `/etc/hosts` empty-clear
  path, and the `addhost`/`delhost` shims (197 assertions, up from 167).

### Fixed
- **zsh completion no longer errors when sourced before `compinit`**:
  `cmdr_completion.bash` loaded `bashcompinit` *after* its first `complete -F`
  call, so a fresh zsh printed `command not found: complete` / `compdef`. It now
  loads bashcompinit first and only registers when `complete`+`compdef` exist;
  `install.sh` adds the `autoload -Uz compinit bashcompinit` line to a zsh rc.
- **`cmdr-install-tool` / doctor tool extraction handles `xargs`**: a tool run as
  `... | xargs -I{} <tool>` is now detected (the `xargs` flags are skipped). The
  known limitation (no descent into `$(...)` / backticks / `bash -c`) is documented.

## [3.3.0]

### Added
- **`--json` output mode**: machine-readable JSON for the read commands
  (`-s`, `-f`, `--history`, `--findings`, `--host list`, `-W`, `--pack list`),
  so CMDR composes with `jq`, scripts, and other tools.
- **`--import <source>`**: pull commands from external sources into the store
  with a preview-then-confirm flow (skip with `-y`, preview-only with `-n`).
  Sources: `history` (recent unique shell history), `tldr <page>`,
  `cheat <topic>` (via curl), and `file <path>` (JSON pack/array or a plain-text
  list). Duplicate tags are auto-uniquified, never overwritten. Honors `--local`.
- **Optional SQLite search index**: when `sqlite3` is present and a store is
  large, `-f`/search is answered from a SQLite mirror instead of a full jq scan.
  The JSON store stays the source of truth; the mirror is rebuilt only when the
  JSON changes. Off by default for small stores (identical output); force with
  `CMDR_INDEX=1`, disable with `CMDR_INDEX=0`. The `.cmdr_index.db` cache is
  kept out of `--sync` via an auto-seeded `.gitignore`.
- **Richer fzf picker**: the bare `cmdr` / `--pick` picker now shows a live
  preview (category, aliases, danger flag, description, full command,
  placeholders, notes, last run) and key bindings — `enter` run, `ctrl-n`
  dry-run, `ctrl-y` copy, `ctrl-/` toggle preview.
- **bats test suite** (`tests/cmdr.bats`) alongside the existing `tests/run.sh`,
  which now also covers `--json`, `--import`, index parity, and run-path locking.

### Changed
- **Modularized `cmdr_functions.sh`** into focused `lib/*.sh` modules loaded by
  a thin loader — same public surface, easier to navigate and test. (No change
  to how `cmdr.sh` is invoked or installed.)
- **Command listing** (`-s`) now renders in a single `jq` pass instead of one
  per category.

### Fixed
- **Run-path write races**: run history and `--capture` env writes now take the
  same short-lived store lock as CRUD writes, so concurrent `cmdr -r` calls no
  longer lose history entries or captured variables.

## [3.2.0]

### Added
- **Workflow engine** (`--flow run|list|import|show`): JSON workflows of
  conditional, capturing, retrying, optionally-parallel steps. Steps support
  `run`, `args` (incl. `@host`), `when`, `capture`, `register`, `retry`,
  `timeout`, `remote`, `continue_on_error`, and `parallel` blocks. Safe
  condition DSL (`env:`/`step:` with `== != contains matches exists`, joined by
  `&& / ||`, negatable). Honors dry-run.
- **Secrets** (`--secret`, `--secrets`, `--secret-clear`): map `{NAME}` to a
  provider (`pass`/`cmd`/`env`/`age`/`file`). Resolved only at execution time,
  so secrets never appear in the stored command, run history, or the on-screen
  command line. Clipboard copy resolves them (for pasting).
- **`--lint`**: validates command stores, packs, and workflows (JSON, empty
  commands, bad tag names, unbalanced placeholders, unknown workflow step refs).
- **Report formats**: `--report` infers format from the file extension or
  `--format md|csv|html|pdf`. CSV exports findings; HTML/PDF via pandoc.
- **Git-backed sync** (`--sync [msg]`, `--sync-remote <url>`): version/share the
  data dir; refuses to run against the CMDR install directory.
- **`@host` tab completion** and completion for workflows/secrets/formats.

## [3.1.0]

### Added
- **Output capture → chaining**: `cmdr -r <tag> --capture VAR[:regex]` stores a
  command's stdout into a workspace env var for use by the next command.
- **Host/target model**: `cmdr --host add/list/rm`. Selecting a host with
  `@name`, `--on`, or `--all-hosts` fills `{TARGET}`/`{RHOST}`/`{RHOSTNAME}`/
  `{OS}`/`{RUSER}`/`{RPORT}`.
- **Remote execution**: `cmdr -r <tag> --on <host>` runs over SSH.
- **Placeholder forms**: `{VAR:=default}` and `{VAR:?}` (required) in commands.
- **Findings & reporting**: `--finding`, `--findings`, and a markdown
  engagement report via `--report [file]`.
- **Run history**: `--history [n]` and re-run with `cmdr -r last` (alias `-r !`).
- **Encrypted workspaces**: `--lock-workspace` / `--unlock-workspace` encrypt a
  named workspace at rest using `age` (falls back to `gpg`).
- **Dangerous commands**: `--danger` marks a command so it always confirms
  before running, even under `-y`.
- **Fuzzy picker**: `--pick` (and a bare `cmdr` on a TTY) to fuzzy-find a
  command via `fzf`, falling back to interactive mode.
- `starter` command pack and an in-repo test suite (`tests/run.sh`) + CI.

### Changed
- Writes are now atomic on all filesystems (temp file created beside the target
  for a same-filesystem rename instead of `/tmp`).
- Locking uses a portable `mkdir` lock (no `flock` dependency; works on macOS)
  and is scoped to mutating actions only, so reads/runs never block other
  terminals.
- `cmdr -r` (and chains/playbooks) propagate the command's real exit code.
- Project-local `.cmdr.json` files are **trust-gated** (content-hash pinned);
  editing a trusted file revokes trust until re-approved.

### Fixed
- Workspace names are sanitized to prevent path traversal.
- macOS Bash 3.2 compatibility (removed `mapfile` usage).
- Display columns no longer misalign when optional fields are empty.
- Dry-run (`-n`) never prompts for missing placeholders; it shows `<name>`
  for the gap instead of blocking.

## [3.0.0]
- Initial public release: command store with tags/aliases/categories,
  workspaces, environment variables, playbooks, chains, notes, output capture,
  command packs, project-local commands, tab completion, dry-run, and undo.
