#!/bin/bash
# SessionStart hook: inject the vault's Index.md so every session starts
# with the second-brain map already in context instead of relying on the
# agent to think to go read it.
#
# Also does the Synapse pointer check (see sb-001 -- Synapse implementation).
# The existence check below is a plain path lookup, never a model call or
# an HTTP round-trip -- that's what keeps this zero-cost for every repo
# that never ran /synapse-init.
CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

INDEX="${OBSIDIAN_VAULT_DIR:-}/Index.md"
LABEL="Obsidian second-brain index"

SYNAPSE_LINE=""
CATALOGUE_BLOCK=""
if [ -n "${OBSIDIAN_VAULT_DIR:-}" ]; then
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

  # Catalogue of the *other* namespaces, so a session that later cd's into a
  # different repo knows that repo's graph exists at all. Without it only the
  # starting repo is ever announced -- and one session routinely spans several
  # repos (a change in one landing in another).
  #
  # Built here, stored nowhere: the source of truth is the directory listing
  # plus each namespace Index.md's existing `remote:` field, so there is nothing
  # to invalidate and it cannot drift. That also keeps this hook read-only
  # against the vault -- only synapse-staleness.sh writes.
  #
  # One `grep` fork regardless of namespace count (`-m1` stops inside each
  # file's frontmatter), then `LC_ALL=C sort` so the injected text is
  # byte-identical across runs and machines: collation is locale-dependent, and
  # the glob's output order is not reliably sorted. Deliberately `grep`, not
  # `rg` -- this ships to machines that may not have ripgrep, and rg measured
  # ~2.9x slower on this workload anyway (pure process-startup cost).
  CATALOGUE_RAW="$(grep -m1 -H '^remote:' "$OBSIDIAN_VAULT_DIR"/synapse/*/Index.md 2>/dev/null || true)"
  if [ -n "$CATALOGUE_RAW" ]; then
    ENTRIES="$(printf '%s\n' "$CATALOGUE_RAW" \
      | sed -e "s#^$OBSIDIAN_VAULT_DIR/synapse/##" \
            -e 's#/Index.md:remote:[[:space:]]*#|#' \
            -e 's/"//g')"
    # Drop this repo's own namespace: it already got the verified pointer above,
    # which carries a stronger guarantee than a catalogue line can.
    if [ -n "${REPO_NAME:-}" ]; then
      ENTRIES="$(printf '%s\n' "$ENTRIES" | grep -v "^$REPO_NAME|" || true)"
    fi
    ENTRIES="$(printf '%s\n' "$ENTRIES" | LC_ALL=C sort | sed '/^$/d')"
    if [ -n "$ENTRIES" ]; then
      CATALOGUE_BLOCK="Other Synapse namespaces in this vault (name | remote). A session that moves into one of these repos can consult synapse/{name}/Index.md for its code graph -- but verify the listed remote against that repo's own \`git remote get-url origin\` first, since a namespace is keyed by directory basename and two unrelated repos can share one:
$ENTRIES"
    fi
  fi
fi

BASE_CONTEXT=""
if [ -f "$INDEX" ]; then
  BASE_CONTEXT="$(jq -nr --rawfile content "$INDEX" --arg path "$INDEX" --arg label "$LABEL" \
    '"\($label) (\($path)) — read before creating or linking any note; prefer linking to an existing note over duplicating content, and fall back to linking this index if nothing more specific applies:\n\n" + $content')"
fi

if [ -n "$BASE_CONTEXT" ] || [ -n "$SYNAPSE_LINE" ] || [ -n "$CATALOGUE_BLOCK" ]; then
  jq -n --arg base "$BASE_CONTEXT" --arg synapse "$SYNAPSE_LINE" --arg catalogue "$CATALOGUE_BLOCK" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ([$base, $synapse, $catalogue] | map(select(. != "")) | join("\n\n"))}}'
fi
