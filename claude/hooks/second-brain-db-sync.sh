#!/bin/bash
# PostToolUse hook (Write|Edit|mcp__obsidian__vault_(write|patch|append|delete|move)):
# keep the active backend's persistence layer in sync immediately after an
# agent-driven note change.
#
# org-roam: update org-roam.db instead of waiting for its own autosync
# (file-watcher) or the next interactive save in Emacs.
#
# obsidian: commit the change to the vault's local git repo (if one exists
# -- this is opt-in per-vault, not assumed). Matches on the MCP vault
# mutation tools too, not just the native Write/Edit tools, since
# /obsidian-note and /obsidian-task write through mcp__obsidian__vault_*
# rather than editing files directly.
CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
BACKEND="${BACKEND:-org-roam}"

if [ "$BACKEND" = "obsidian" ]; then
  VAULT="${OBSIDIAN_VAULT_DIR:-}"
  [ -n "$VAULT" ] && [ -d "$VAULT/.git" ] || exit 0
  cd "$VAULT" || exit 0
  git add -A
  git diff --cached --quiet && exit 0
  git commit --quiet -m "auto: vault edit via Claude Code" || true
  exit 0
fi

[ "$BACKEND" = "org-roam" ] || exit 0

ROAM_DIR="${ORG_ROAM_DIR:-$HOME/Roam}"
SOCK="$HOME/.emacs.d/var/server/server"

INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')"

[ -n "$FILE" ] || exit 0
case "$FILE" in
  "$ROAM_DIR"/*.org) ;;
  *) exit 0 ;;
esac

[ -S "$SOCK" ] || exit 0
emacsclient --socket-name="$SOCK" --eval "(org-roam-db-update-file \"$FILE\")" >/dev/null 2>&1 || true
