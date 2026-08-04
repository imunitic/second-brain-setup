#!/bin/bash
# Stop hook: every N turns, force a genuine "is anything worth capturing in
# Synapse Vault" check-in. Uses hookSpecificOutput.additionalContext (not
# decision:block) -- an earlier predecessor hook used this same shape and
# reliably produced immediate, visible action, with the CLI labeling it
# "Stop hook feedback" instead of the alarming-looking "Stop hook error"
# that decision:block renders as. Switched back to this shape 2026-07-23
# specifically for the better label -- confirm empirically that it still
# fires immediately; if it turns out to silently defer instead, revert to
# decision:block. Mirrors a similar hook from another setup, adapted to
# this repo's Obsidian-backed Synapse Vault, with no reference to a
# /wrapup-style command, which isn't used here.
N=25
STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR"

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

LOCATION="${OBSIDIAN_VAULT_DIR:-the Obsidian vault}"
CMD="/synapse-note"

INPUT="$(cat)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // "default"')"
TOTAL_FILE="$STATE_DIR/synapse-stop-nudge-total-$SID"
SINCE_FILE="$STATE_DIR/synapse-stop-nudge-since-$SID"

TOTAL=$(( $(cat "$TOTAL_FILE" 2>/dev/null || echo 0) + 1 ))
SINCE=$(( $(cat "$SINCE_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$TOTAL" > "$TOTAL_FILE"

if [ "$SINCE" -ge "$N" ]; then
  echo 0 > "$SINCE_FILE"
  jq -n --arg location "$LOCATION" --arg cmd "$CMD" --arg total "$TOTAL" --arg n "$N" '
    {
      hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: ("This session has grown substantial (\($total) turns, re-armed at the " + $n + "-turn mark). Before continuing: did this session produce a debugging/investigation/research finding, decision, or piece of context worth persisting to Synapse Vault (\($location))? If so, write it up now (see the global CLAUDE.md \"Synapse Vault as permanent memory\" section, or use " + $cmd + ") while full context is still available -- do not wait for a wrap-up step. If you already wrote or updated a note earlier this session, check whether anything since then is worth folding in too.")
      }
    }'
else
  echo "$SINCE" > "$SINCE_FILE"
fi
