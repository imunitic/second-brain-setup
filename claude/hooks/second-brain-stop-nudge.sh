#!/bin/bash
# Stop hook: every N turns, force a genuine "is anything worth capturing in
# the second brain" check-in via decision:block -- this feeds the reason
# back to Claude and prevents the turn from ending, so it's a real forced
# response rather than a silently-injected PostToolUse reminder (which this
# replaces). Mirrors a similar hook from another setup, adapted to this
# repo's backend-agnostic second brain (org-roam <-> obsidian) and with no
# reference to a /wrapup-style command, which isn't used here.
N=100
STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR"

CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
BACKEND="${BACKEND:-org-roam}"

if [ "$BACKEND" = "obsidian" ]; then
  LOCATION="${OBSIDIAN_VAULT_DIR:-the Obsidian vault}"
  CMD="/obsidian-note"
else
  LOCATION="${ORG_ROAM_DIR:-$HOME/Roam}"
  CMD="/roam-note"
fi

INPUT="$(cat)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // "default"')"
TOTAL_FILE="$STATE_DIR/second-brain-stop-nudge-total-$SID"
SINCE_FILE="$STATE_DIR/second-brain-stop-nudge-since-$SID"

TOTAL=$(( $(cat "$TOTAL_FILE" 2>/dev/null || echo 0) + 1 ))
SINCE=$(( $(cat "$SINCE_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$TOTAL" > "$TOTAL_FILE"

if [ "$SINCE" -ge "$N" ]; then
  echo 0 > "$SINCE_FILE"
  jq -n --arg location "$LOCATION" --arg cmd "$CMD" --arg total "$TOTAL" --arg n "$N" '
    {
      decision: "block",
      reason: ("This session has grown substantial (\($total) turns, re-armed at the " + $n + "-turn mark). Before continuing: did this session produce a debugging/investigation/research finding, decision, or piece of context worth persisting to the second brain (\($location))? If so, write it up now (see the global CLAUDE.md \"Second brain as permanent memory\" section, or use " + $cmd + ") while full context is still available -- do not wait for a wrap-up step. If you already wrote or updated a note earlier this session, check whether anything since then is worth folding in too.")
    }'
else
  echo "$SINCE" > "$SINCE_FILE"
fi
