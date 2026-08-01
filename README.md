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
- `claude/hooks/second-brain-*.sh` — SessionStart index injection (also
  does the Synapse pointer check, obsidian-only — see below), a
  turn-count-based Stop hook that forces a "worth capturing?" check-in
  every 100 turns via `decision: "block"`, and org-roam db-sync (a no-op
  under the obsidian backend, since the MCP server reads live file state
  directly).
- `claude/commands/roam-note.md`, `claude/commands/obsidian-note.md` —
  note-creation commands (bare/`--task`/`--list`/`--search` modes).
- `claude/commands/obsidian-design-note.md`, `claude/commands/obsidian-task-note.md` —
  Obsidian-native counterparts to `claude-code-setup`'s `/design-note`/`/task-note`: a personal
  design-discussion → compiled-checklist pipeline that lives in the vault (`designs/`, `projects/`)
  instead of a repo's gitignored `docs/notes/`, so it's cross-project by default. Task-note creation
  and status tracking delegate to `obsidian-note.md --task` and `skills/obsidian-task/` above, not a
  separate mechanism.
- `claude/skills/org-task/`, `claude/skills/obsidian-task/` — proactive
  task-status tracking skills.
- **Synapse** (obsidian backend only) — a per-repo semantic code graph hosted in the vault under
  `synapse/{repo-name}/`, so Claude Code doesn't re-explore a codebase from scratch every session.
  Dormant until `/synapse-init` is run in a repo. See [[sb — Synapse (Obsidian code-graph
  layer)]] in the vault for the full design.
  - `claude/commands/synapse-init.md` — first-time build (per-file-summary-then-cluster pass into
    node notes + the two derived projections) and the manual `_unassigned`-sweep fallback for an
    already-initialized, otherwise-dormant repo.
  - `claude/hooks/synapse-staleness.sh` — `PostToolUse` (`Write|Edit|MultiEdit`) Tier 1: flags
    edited files' nodes `stale` (or queues a brand-new file into `_unassigned`) via the Local REST
    API directly, no MCP round-trip.
  - `claude/skills/synapse-node/` — Tier 2: the lazy staleness check + regeneration + unassigned
    sweep Claude runs itself whenever a node's body is actually read, not a hook.

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

## Testing

```sh
brew install bats-core   # if not already installed
bats tests/
```

Covers `setup.sh` (idempotent install/merge into a scratch `$HOME`),
`second-brain-session-start.sh` (index injection + the Synapse pointer
check, pure git/filesystem, no network), and `synapse-staleness.sh`
(Tier 1 staleness flagging, with `tests/fixtures/fake-bin/curl` stubbing
out the Obsidian Local REST API so no real vault or plugin is needed).
Every test runs against a throwaway `$HOME`/git repo/vault created in
`tests/test_helper.bash` — nothing here touches your real `~/.claude` or
vault.

Not covered by these tests: `claude/commands/synapse-init.md` and
`claude/skills/synapse-node/SKILL.md` are natural-language procedures
Claude follows, not code — there's nothing for a test framework to
execute there.

## Dependencies

`jq`, `bats-core` (tests only), `pandoc` (if you ever need to re-run the
org→Obsidian conversion scripts — not included here, they were one-off
migration scripts, not part of the ongoing tooling), `sqlite3` (org-roam
backend only), the `claude` CLI.
