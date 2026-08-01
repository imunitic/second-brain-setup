#!/bin/bash
# SessionStart hook: inject the active second-brain backend's index note
# so every session starts with the second-brain map already in context
# instead of relying on the agent to think to go read it.
#
# Also does the Synapse pointer check (see sb-001 -- Synapse implementation):
# obsidian-only, since Synapse nodes live in the vault. The existence check
# below is a plain path lookup, never a model call or an HTTP round-trip --
# that's what keeps this zero-cost for every repo that never ran
# /synapse-init.
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

SYNAPSE_LINE=""
if [ "$BACKEND" = "obsidian" ] && [ -n "${OBSIDIAN_VAULT_DIR:-}" ]; then
  INPUT="$(cat)"
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
  [ -n "$CWD" ] || CWD="$PWD"

  REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$REPO_ROOT" ]; then
    REPO_NAME="$(basename "$REPO_ROOT")"
    REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    if [ -z "$REMOTE" ]; then
      FIRST_REMOTE="$(git -C "$REPO_ROOT" remote 2>/dev/null | head -1 || true)"
      [ -n "$FIRST_REMOTE" ] && REMOTE="$(git -C "$REPO_ROOT" remote get-url "$FIRST_REMOTE" 2>/dev/null || true)"
    fi
    [ -n "$REMOTE" ] || REMOTE="$REPO_ROOT"

    SYNAPSE_INDEX="$OBSIDIAN_VAULT_DIR/synapse/$REPO_NAME/Index.md"
    if [ -f "$SYNAPSE_INDEX" ]; then
      EXISTING_REMOTE="$(grep -m1 '^remote:' "$SYNAPSE_INDEX" | sed -e 's/^remote: *//' -e 's/^"//' -e 's/"$//')"
      if [ "$EXISTING_REMOTE" = "$REMOTE" ]; then
        SYNAPSE_LINE="Synapse namespace for this repo: synapse/$REPO_NAME/Index.md -- consult it for existing code-graph nodes before re-exploring from scratch."
      else
        SYNAPSE_LINE="Synapse namespace synapse/$REPO_NAME/ exists but its remote (\"$EXISTING_REMOTE\") doesn't match this repo's (\"$REMOTE\") -- likely a different repo sharing this basename. Skipping the pointer rather than risk cross-project contamination."
      fi
    fi
  fi
fi

BASE_CONTEXT=""
if [ -f "$INDEX" ]; then
  BASE_CONTEXT="$(jq -nr --rawfile content "$INDEX" --arg path "$INDEX" --arg label "$LABEL" \
    '"\($label) (\($path)) — read before creating or linking any note; prefer linking to an existing note over duplicating content, and fall back to linking this index if nothing more specific applies:\n\n" + $content')"
fi

if [ -n "$BASE_CONTEXT" ] || [ -n "$SYNAPSE_LINE" ]; then
  jq -n --arg base "$BASE_CONTEXT" --arg synapse "$SYNAPSE_LINE" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ([$base, $synapse] | map(select(. != "")) | join("\n\n"))}}'
fi
