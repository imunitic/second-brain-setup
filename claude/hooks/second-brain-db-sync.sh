#!/bin/bash
# PostToolUse hook (Write|Edit): keep the org-roam.db index in sync
# immediately after an agent writes/edits a note file, instead of waiting
# for org-roam's own autosync (file-watcher) or the next interactive save
# in Emacs. No-op for the obsidian backend -- the MCP server reads live
# file state directly, there's no separate index db to resync.
CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
BACKEND="${BACKEND:-org-roam}"

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
