#!/bin/bash
# PostToolUse hook (all tools): every N tool-calls in a session, nudge the
# agent to actively check whether anything since the last nudge belongs in
# the second brain (active backend per ~/.claude/second-brain.conf).
# Counting tool calls rather than pure user turns overcounts slightly, but
# that's fine -- the point is a periodic forced check-in, not a precise
# cadence.
N=30
STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR"

CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
BACKEND="${BACKEND:-org-roam}"

if [ "$BACKEND" = "obsidian" ]; then
  LOCATION="${OBSIDIAN_VAULT_DIR:-the Obsidian vault}"
else
  LOCATION="${ORG_ROAM_DIR:-$HOME/Roam}"
fi

INPUT="$(cat)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // "default"')"
FILE="$STATE_DIR/second-brain-nudge-$SID"

COUNT=$(( $(cat "$FILE" 2>/dev/null || echo 0) + 1 ))

if [ "$COUNT" -ge "$N" ]; then
  echo 0 > "$FILE"
  jq -n --arg location "$LOCATION" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("Second-brain check-in (every ~30 tool calls): has anything in this stretch of the session been worth capturing in the second brain (\($location))? A new note, a link between existing notes, or an update to a note that is now stale? If yes, do it now, following the linking-priority and folder rules in CLAUDE.md. If genuinely nothing qualifies, continue without comment.")}}'
else
  echo "$COUNT" > "$FILE"
fi
