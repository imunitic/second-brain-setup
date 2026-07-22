#!/bin/bash
# SessionStart hook: inject the active second-brain backend's index note
# so every session starts with the second-brain map already in context
# instead of relying on the agent to think to go read it.
CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
BACKEND="${BACKEND:-org-roam}"

if [ "$BACKEND" = "obsidian" ]; then
  INDEX="${OBSIDIAN_VAULT_DIR:-}/Index.md"
  LABEL="Obsidian second-brain index"
else
  INDEX="${ORG_ROAM_DIR:-$HOME/Roam}/index.org"
  LABEL="Org-roam second-brain index"
fi

if [ -f "$INDEX" ]; then
  jq -n --rawfile content "$INDEX" --arg path "$INDEX" --arg label "$LABEL" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ("\($label) (\($path)) — read before creating or linking any note; prefer linking to an existing note over duplicating content, and fall back to linking this index if nothing more specific applies:\n\n" + $content)}}'
fi
