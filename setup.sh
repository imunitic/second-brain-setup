#!/bin/bash
# Installs the portable second-brain tooling (CLAUDE.md, hooks, commands,
# skills) into ~/.claude on this machine. Merges into existing
# settings.json rather than overwriting it. Does NOT touch Obsidian
# itself, plugin installs, API keys/certs, or note content -- see
# setup-obsidian-mcp.sh and the README for those.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/claude"
DEST="$HOME/.claude"

command -v jq >/dev/null || { echo "jq is required. Install it first (e.g. brew install jq)." >&2; exit 1; }

mkdir -p "$DEST/hooks" "$DEST/commands" "$DEST/skills/sb-task" "$DEST/skills/synapse-node" "$DEST/bin"

echo "== CLAUDE.md =="
if [ -f "$DEST/CLAUDE.md" ] && ! diff -q "$SRC/CLAUDE.md" "$DEST/CLAUDE.md" >/dev/null 2>&1; then
  echo "  ~/.claude/CLAUDE.md already exists and differs -- not overwriting."
  echo "  Diff manually and merge: diff '$SRC/CLAUDE.md' '$DEST/CLAUDE.md'"
else
  cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"
  echo "  installed."
fi

echo "== second-brain.conf =="
if [ -f "$DEST/second-brain.conf" ]; then
  echo "  already exists, leaving in place: $DEST/second-brain.conf"
else
  cp "$SRC/second-brain.conf.template" "$DEST/second-brain.conf"
  echo "  installed from template -- EDIT THIS FILE (paths are machine-specific): $DEST/second-brain.conf"
fi

echo "== second-brain-projects.conf =="
if [ -f "$DEST/second-brain-projects.conf" ]; then
  echo "  already exists, leaving in place: $DEST/second-brain-projects.conf"
else
  cp "$SRC/second-brain-projects.conf.template" "$DEST/second-brain-projects.conf"
  echo "  installed from template -- machine-local, self-managed by /sb-note: $DEST/second-brain-projects.conf"
fi

echo "== hooks/commands/skills =="
cp "$SRC/hooks/"*.sh "$DEST/hooks/"
chmod +x "$DEST/hooks/"*.sh
cp "$SRC/commands/"*.md "$DEST/commands/"
cp "$SRC/skills/sb-task/SKILL.md" "$DEST/skills/sb-task/SKILL.md"
cp "$SRC/skills/synapse-node/SKILL.md" "$DEST/skills/synapse-node/SKILL.md"
cp "$SRC/bin/synapse-tags.sh" "$DEST/bin/synapse-tags.sh"
chmod +x "$DEST/bin/synapse-tags.sh"
echo "  installed."
if [ -d "$DEST/skills/obsidian-task" ] || [ -f "$DEST/bin/second-brain-switch" ] || ls "$DEST/commands/obsidian-"*.md >/dev/null 2>&1 || [ -d "$DEST/skills/org-task" ]; then
  echo "  NOTE: found stale files from before the sb- rename / org-roam removal --"
  echo "    $DEST/skills/obsidian-task/, $DEST/skills/org-task/, $DEST/bin/second-brain-switch,"
  echo "    $DEST/commands/obsidian-*.md are no longer installed by this script and are safe"
  echo "    to remove by hand."
fi

echo "== settings.json hook wiring =="
SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TMP="$(mktemp)"
jq '
  .hooks = (.hooks // {}) |
  .hooks.SessionStart = (.hooks.SessionStart // []) |
  .hooks.PostToolUse = (.hooks.PostToolUse // []) |
  .hooks.Stop = (.hooks.Stop // []) |
  (if any(.hooks.SessionStart[]?.hooks[]?; .command == "bash ~/.claude/hooks/second-brain-session-start.sh")
   then . else .hooks.SessionStart += [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-session-start.sh"}]}] end) |
  (if any(.hooks.PostToolUse[]?.hooks[]?; .command == "bash ~/.claude/hooks/second-brain-db-sync.sh")
   then . else .hooks.PostToolUse += [{"matcher":"Write|Edit|mcp__obsidian__vault_(write|patch|append|delete|move)","hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-db-sync.sh"}]}] end) |
  (if any(.hooks.PostToolUse[]?.hooks[]?; .command == "bash ~/.claude/hooks/synapse-staleness.sh")
   then . else .hooks.PostToolUse += [{"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-staleness.sh"}]}] end) |
  (if any(.hooks.Stop[]?.hooks[]?; .command == "bash ~/.claude/hooks/second-brain-stop-nudge.sh")
   then . else .hooks.Stop += [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-stop-nudge.sh"}]}] end)
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
echo "  merged (idempotent -- safe to re-run)."

cat <<'EOF'

== Done with the automatable part. Manual steps remaining: ==

1. Edit ~/.claude/second-brain.conf -- set OBSIDIAN_VAULT_DIR for this
   machine.
2. Install Obsidian.app, open your vault.
3. Settings -> Community plugins -> Browse -> install + enable:
   "Local REST API with MCP", "Headless Mode", "Iconic" (optional).
4. Run: ./setup-obsidian-mcp.sh <path-to-vault>
   (extracts the plugin's generated cert + API key, registers the
   MCP server, wires up NODE_EXTRA_CA_CERTS -- all automatic once
   the plugin is installed and has generated its data.json).
5. Optionally add Obsidian to login items and enable "Start headless"
   in the Headless Mode plugin settings, so it runs like a background
   daemon (see README).
6. Restart Claude Code so the new hooks/settings/MCP registration
   actually take effect for the running session.
EOF
