# CMDR workflow: from a fresh box to running recon

A task-oriented walkthrough of the host, tool-health, and tool-install features.
For the full flag reference see [README.md](../README.md); every command below
also has `cmdr <flag> --help`.

The running example is an HTB-style engagement against `10.129.51.189`
(`snapped.htb`), from a machine where the recon tools aren't installed yet.

---

## 0. One-time install

```bash
git clone https://github.com/SP1R4/CMDR.git && cd CMDR
./install.sh
```

The installer offers an alias or a `~/.local/bin` symlink, wires up tab
completion, and (opt-in) enables the `addhost` / `synchosts` / `delhost` shell
shims and exposes `cmdr-install-tool` on your `PATH`. Reload your shell
afterwards (`source ~/.zshrc`, or open a new terminal).

> **zsh + go tools:** tools installed via a `go` recipe land in
> `$(go env GOPATH)/bin` — make sure that's on your `PATH`.

---

## 1. Start an engagement workspace

Workspaces isolate commands, hosts, env, findings, and history per engagement.

```bash
cmdr -w snapped            # create/switch to a workspace
cmdr --pack load pentest-recon   # subfinder/httpx/naabu/nuclei/... (14 cmds)
```

Right after a pack load, CMDR tells you which tools it references that you don't
have yet:

```
Imported 14 commands (0 skipped).
Missing tools for the imported commands: dnsx gau httpx katana masscan naabu nuclei subfinder waybackurls
  install them:  cmdr-install-tool dnsx gau httpx ...   (or --all-missing)
```

Other useful packs: `pentest-web` (ffuf, feroxbuster, katana, sqlmap, dalfox,
wpscan…), `pentest-ad`, `pentest-pivot`. `cmdr --pack list` shows them all.

---

## 2. Add the target host

One command adds the host to the workspace inventory **and** writes it to
`/etc/hosts` so `snapped.htb` resolves:

```bash
cmdr --host add 10.129.51.189 --name snapped \
     --hostname 'snapped.htb admin.snapped.htb' --etc
```

`--hostname` accepts several space-separated names; the first is canonical for
`{RHOSTNAME}`/SSH, all of them go into `/etc/hosts`. Or use the muscle-memory
shim (identical effect):

```bash
addhost 10.129.51.189 snapped.htb admin.snapped.htb
```

Inspect and manage:

```bash
cmdr --host list              # marks which hosts are in /etc/hosts
cmdr --host sync-etc          # re-mirror the whole workspace to /etc/hosts (idempotent)
cmdr --host sync-etc --clear  # remove this workspace's /etc/hosts block
cmdr --host rm snapped        # drop from inventory (then sync-etc to tidy /etc/hosts)
```

### How the /etc/hosts block works

CMDR owns a delimited, per-workspace block and rewrites it wholesale on every
sync — entries never duplicate, and anything outside the markers is preserved:

```
# >>> cmdr:snapped >>>
# managed by 'cmdr --host sync-etc' — lines between the markers are overwritten
10.129.51.189   snapped.htb admin.snapped.htb
# <<< cmdr:snapped <<<
```

- `sudo` is used **only** when `/etc/hosts` isn't already writable *and* the
  content changed — no needless prompt on a no-op.
- A one-time `/etc/hosts.cmdr.bak` backup is kept; the macOS DNS cache is
  flushed after a change.
- A hand-added entry for a managed name is reported and left untouched.
- `$CMDR_ETC_HOSTS` overrides the target file (used by tests / non-root flows).

---

## 3. Check tool health and install what's missing

See exactly what the loaded commands need and what's missing:

```bash
cmdr --doctor                 # whole store: each tool -> ok / missing
cmdr --doctor recon-chain     # just the tools one command pipes together
cmdr --doctor --json          # [{tool, present, path}] for scripting
```

`--doctor` exits non-zero when anything is missing and prints the exact install
line. Install the gaps — **fail-closed**: it prints a plan and installs nothing
until you pass `-y` or confirm:

```bash
cmdr-install-tool --all-missing -n   # dry-run the plan first
cmdr-install-tool --all-missing -y   # install everything the store needs
cmdr-install-tool --for recon-chain  # just one command's tools
cmdr-install-tool subfinder httpx    # specific tools
```

It picks the best method per platform (macOS `brew` > `go` > `pipx`; Linux
`apt` > `go` > `pipx`), skips what's present, and reports anything with no
recipe instead of guessing. Teach it a new tool by adding a row to
[`contrib/tool-recipes.tsv`](../contrib/tool-recipes.tsv).

After installing, re-check: `cmdr --doctor` should read `N present, 0 missing`.

---

## 4. Run recon against the host

Selecting a host fills `{TARGET}` / `{RHOST}` / `{RHOSTNAME}` / `{OS}` /
`{RUSER}` / `{RPORT}` in any command:

```bash
cmdr -r recon-subfinder snapped.htb           # positional fills {DOMAIN}
cmdr -r recon-naabu @snapped                  # @name pulls host vars -> {TARGET}
cmdr -r recon-httpx @snapped --save           # tee output into the workspace
cmdr -r recon-chain snapped.htb               # subfinder|dnsx|httpx|nuclei pipeline
```

Preview without running, or copy instead of running:

```bash
cmdr -n -r recon-naabu @snapped   # dry-run: prints the resolved command
cmdr -c recon-httpx @snapped      # copy resolved command to clipboard
```

Chain output into the next step:

```bash
cmdr -r login @snapped --capture 'TOKEN:eyJ[A-Za-z0-9._-]+'
cmdr -r list-users @snapped        # uses {TOKEN}
```

---

## 5. Record findings and report

```bash
cmdr --finding high snapped "Unauth admin panel at admin.snapped.htb" --evidence outputs/httpx_*.log
cmdr --findings                    # list
cmdr --report engagement.md        # markdown (hosts + findings + history)
cmdr --history                     # what ran, with exit codes
```

---

## 6. Close out

```bash
cmdr --host sync-etc --clear       # remove the workspace's /etc/hosts block
cmdr --lock-workspace snapped      # encrypt the workspace at rest (age/gpg)
cmdr -w default                    # back to the default workspace
```

---

## Cheat sheet

| Goal | Command |
|------|---------|
| New engagement workspace | `cmdr -w <name>` |
| Load recon commands | `cmdr --pack load pentest-recon` |
| Add host + /etc/hosts | `cmdr --host add <ip> --name <n> --hostname '<fqdn ...>' --etc` |
| Same, shim | `addhost <ip> <fqdn> [fqdn ...]` |
| Re-sync /etc/hosts | `cmdr --host sync-etc` |
| What tools are missing? | `cmdr --doctor` |
| Install the missing tools | `cmdr-install-tool --all-missing -y` |
| Run against a host | `cmdr -r <tag> @<host>` |
| Record a finding | `cmdr --finding <sev> <host> "title"` |
| Build the report | `cmdr --report <file>` |
