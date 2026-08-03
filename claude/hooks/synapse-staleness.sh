#!/bin/bash
# PostToolUse hook (Write|Edit|MultiEdit): Synapse Tier 1 staleness flagging.
# A hook is a plain script, not an agent turn -- it already knows with
# certainty which file just changed, so this is pure bookkeeping (no
# git-hash verification, that's Tier 2 at read time). Talks to the Obsidian
# Local REST API directly rather than through the mcp__obsidian__ tools,
# same reasoning as second-brain-db-sync.sh.
set -euo pipefail

CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 0

PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"
[ -f "$PLUGIN_DATA" ] && [ -f "$CERT" ] || exit 0
command -v jq >/dev/null || exit 0

API_KEY="$(jq -r '.apiKey // empty' "$PLUGIN_DATA")"
PORT="$(jq -r '.port // empty' "$PLUGIN_DATA")"
[ -n "$API_KEY" ] && [ -n "$PORT" ] || exit 0
BASE="https://127.0.0.1:$PORT"

INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')"
[ -n "$FILE" ] || exit 0
[ -f "$FILE" ] || exit 0

REPO_ROOT="$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || exit 0
REPO_NAME="$(basename "$REPO_ROOT")"

# Resolve FILE's directory to its physical (symlink-free) path before the
# prefix strip below -- git rev-parse --show-toplevel already resolves
# symlinks in REPO_ROOT (e.g. macOS /tmp -> /private/tmp), but tool_input's
# file_path may not be, and a raw string-prefix match would silently miss
# every edit in a project reached through a symlinked path.
FILE_DIR="$(cd "$(dirname "$FILE")" && pwd -P)"
FILE="$FILE_DIR/$(basename "$FILE")"

# Repo-relative path -- the form every node's `sources` list and
# _index.json key are written in.
case "$FILE" in
  "$REPO_ROOT"/*) REL="${FILE#"$REPO_ROOT"/}" ;;
  *) exit 0 ;;
esac

urlencode_path() {
  # Percent-encode each path segment (spaces, em dashes, etc. are common
  # in node titles) without touching the '/' separators.
  local path="$1" seg out=()
  local IFS='/'
  read -ra parts <<< "$path"
  for seg in "${parts[@]}"; do
    out+=("$(jq -rn --arg s "$seg" '$s|@uri')")
  done
  local IFS='/'
  echo "${out[*]}"
}

INDEX_VAULT_PATH="synapse/$REPO_NAME/_index.json"
INDEX_URL="$BASE/vault/$(urlencode_path "$INDEX_VAULT_PATH")"

INDEX_RESPONSE="$(curl -s -w '\n%{http_code}' --cacert "$CERT" -H "Authorization: Bearer $API_KEY" "$INDEX_URL" || true)"
HTTP_CODE="$(printf '%s' "$INDEX_RESPONSE" | tail -n1)"
INDEX_JSON="$(printf '%s' "$INDEX_RESPONSE" | sed '$d')"

# No namespace for this repo at all -- the whole point of the opt-in
# /synapse-init step is that this is the only cost paid for a project that
# never ran it, and even this is only reached on an actual edit, not per turn.
# Checking the HTTP status (not just "is the body valid JSON") matters: a 404
# from a nonexistent _index.json comes back as a JSON error body
# (`{"message":"Not Found",...}`), which would otherwise pass a bare `jq -e .`
# check and get a stray `_unassigned` field written onto it.
[ "$HTTP_CODE" = "200" ] || exit 0
printf '%s' "$INDEX_JSON" | jq -e . >/dev/null 2>&1 || exit 0

NODES="$(printf '%s' "$INDEX_JSON" | jq -r --arg rel "$REL" '.[$rel] // [] | .[]' 2>/dev/null || true)"

if [ -z "$NODES" ]; then
  # Genuinely new file, not yet claimed by any node -- queue it for the
  # _unassigned sweep (see /synapse-init's "Re-running on an initialized
  # project" and the Tier 2 read-time procedure).
  UPDATED="$(printf '%s' "$INDEX_JSON" | jq --arg rel "$REL" '
    .["_unassigned"] = ((.["_unassigned"] // []) + [$rel] | unique)
  ')"
  curl -s -o /dev/null --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
    -X PUT -H "Content-Type: application/json" --data-binary "$UPDATED" "$INDEX_URL"
  exit 0
fi

# Flag each owning node stale by read-modify-write, NOT by
# `PATCH -H "Target-Type: frontmatter"`. That call is not field-local: it
# re-serialises the entire YAML block, stripping quotes from every value,
# folding long `title:` lines across two lines, and YAML-coercing anything
# that looks like another type. Verified 2026-08-03 on a node-shaped fixture:
# an all-digit `hash` became `1.1111111111111112e+39`, unrecoverably. Since a
# corrupted hash makes `sources_digest` disagree with its own `sources`
# forever, that would be a permanent false-positive no rebuild can clear.
#
# Rewriting only the one `stale:` line inside the frontmatter leaves every
# other byte -- including the exhaustive `sources` list -- untouched.
set_stale_true() {
  awk '
    NR == 1 && $0 == "---" { in_fm = 1; print; next }
    in_fm && $0 == "---" {
      if (!done) { print "stale: true"; done = 1 }
      in_fm = 0; print; next
    }
    in_fm && !done && /^stale:[[:space:]]*/ { print "stale: true"; done = 1; next }
    { print }
  ' "$1"
}

while IFS= read -r node; do
  [ -n "$node" ] || continue
  NODE_URL="$BASE/vault/$(urlencode_path "synapse/$REPO_NAME/$node")"

  ORIG="$(mktemp)"; NEXT="$(mktemp)"
  if ! curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
        -H "Accept: text/markdown" -o "$ORIG" "$NODE_URL"; then
    rm -f "$ORIG" "$NEXT"
    continue
  fi

  set_stale_true "$ORIG" > "$NEXT"

  # Already stale (or no frontmatter to touch) -- skip the write entirely
  # rather than churn the file's mtime on every edit.
  if cmp -s "$ORIG" "$NEXT"; then
    rm -f "$ORIG" "$NEXT"
    continue
  fi

  curl -s -o /dev/null --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
    -X PUT -H "Content-Type: text/markdown" --data-binary "@$NEXT" "$NODE_URL"
  rm -f "$ORIG" "$NEXT"
done <<< "$NODES"
