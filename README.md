# second-brain-setup

Portable packaging of the backend-agnostic second-brain tooling (org-roam ⟷
Obsidian) built for Claude Code. Covers the *tooling* only — not your actual
notes/vault content, which is a separate sync concern (git, Obsidian Sync,
iCloud, manual copy — your call).

## What's in here (fully portable, no secrets)

- `claude/CLAUDE.md` — the global memory-system instructions.
- `claude/second-brain.conf.template` — backend + path config (edit paths
  per machine).
- `claude/bin/second-brain-switch` — one-line backend switch command.
- `claude/hooks/second-brain-*.sh` — SessionStart index injection, periodic
  nudge, org-roam db-sync (no-ops for the obsidian backend).
- `claude/commands/roam-note.md`, `claude/commands/obsidian-note.md` —
  note-creation commands (bare/`--task`/`--list`/`--search` modes).
- `claude/skills/org-task/`, `claude/skills/obsidian-task/` — proactive
  task-status tracking skills.

## What's NOT portable (per-machine, regenerated fresh each time)

- The Obsidian Local REST API plugin's self-signed cert + API key — each
  install generates its own. `setup-obsidian-mcp.sh` extracts these
  *after* you've installed the plugin, it doesn't carry them over from
  another machine.
- The `obsidian` MCP server registration in `~/.claude.json` (contains the
  bearer token — machine-local, not meant to be copied/committed).
- `NODE_EXTRA_CA_CERTS` in `~/.claude/settings.json` (path is
  machine-specific anyway).

## New machine setup

```sh
git clone <this repo> ~/second-brain-setup   # or copy the folder over
cd ~/second-brain-setup
./setup.sh
```

`setup.sh` installs the portable tooling into `~/.claude/`, merges hook
entries into `~/.claude/settings.json` (idempotent — safe to re-run,
doesn't clobber unrelated settings), and prints the manual steps below.

### If using the `obsidian` backend

1. Install Obsidian, open (or create) your vault.
2. **Settings → Community plugins → Browse**, install + enable:
   - **Local REST API with MCP** (required — the actual bridge)
   - **Headless Mode** (optional but recommended — lets Obsidian run as a
     background daemon with no visible window; enable "Start headless" in
     its settings)
   - **Iconic** (optional — folder/file icons)
3. Run:
   ```sh
   ./setup-obsidian-mcp.sh /path/to/your/vault
   ```
   This extracts the plugin's generated cert + API key, wires
   `NODE_EXTRA_CA_CERTS`, and registers the `obsidian` MCP server at user
   scope (available from any project, any directory). Safe to re-run if
   you ever reinstall the plugin (new cert/key each time).
4. Edit `~/.claude/second-brain.conf`: set `OBSIDIAN_VAULT_DIR` to the
   vault path, and `BACKEND=obsidian`.
5. (Recommended) Add Obsidian to macOS login items so it's always running:
   ```sh
   osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Obsidian.app", hidden:false}'
   ```
6. Restart Claude Code.

### If using the `org-roam` backend

1. Set up Emacs + org-roam per your own config (not covered here — this
   repo assumes you already have an org-roam vault and an Emacs daemon
   reachable via `emacsclient`).
2. Edit `~/.claude/second-brain.conf`: set `ORG_ROAM_DIR` to your vault
   path, and `BACKEND=org-roam`.
3. Restart Claude Code.

## Switching backends later

```sh
~/.claude/bin/second-brain-switch obsidian   # or org-roam
```

Takes effect immediately for hooks (fresh bash process each firing —
no restart needed). A session's own MCP tool availability (e.g. whether
`mcp__obsidian__*` tools are loaded) is still fixed at that session's
startup, so a running session needs a restart to pick up a switch either
way.

## Dependencies

`jq`, `pandoc` (if you ever need to re-run the org→Obsidian conversion
scripts — not included here, they were one-off migration scripts, not
part of the ongoing tooling), `sqlite3` (org-roam backend only), the
`claude` CLI.
