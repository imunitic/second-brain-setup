#!/bin/bash
# Synapse Tier 2 batch verification: prints the titles of nodes whose covered
# files no longer match what the node recorded, and nothing else.
#
# Usage: synapse-verify.sh [repo-path]      (defaults to $PWD)
#
# Why a script rather than a procedure Claude follows: answering "has this node
# changed" needs the node's path list, and both places that list lives are far
# too expensive to read into context -- a hub node's own `sources` runs to ~38k
# tokens, and `_index.json` to ~350k. Done here, the whole project costs one
# `git hash-object` fork plus one GET per node, and the only thing that reaches
# a context window is the list of stale titles. Same architecture as
# synapse-staleness.sh: bash + jq + curl, never a context read.
#
# Exit codes:
#   0 - ran successfully (whether or not anything was stale; check stdout)
#   1 - could not run (missing dependency, no vault, no namespace, remote
#       mismatch). Callers should treat this as "no information", not "clean".
set -uo pipefail

REPO_ARG="${1:-$PWD}"

CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 1

command -v jq >/dev/null || exit 1
command -v git >/dev/null || exit 1

# sha256, portable across macOS (shasum) and most Linux (sha256sum).
if command -v shasum >/dev/null; then
  sha256() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null; then
  sha256() { sha256sum | cut -d' ' -f1; }
else
  exit 1
fi

PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"
[ -f "$PLUGIN_DATA" ] && [ -f "$CERT" ] || exit 1
API_KEY="$(jq -r '.apiKey // empty' "$PLUGIN_DATA")"
PORT="$(jq -r '.port // empty' "$PLUGIN_DATA")"
[ -n "$API_KEY" ] && [ -n "$PORT" ] || exit 1
BASE="https://127.0.0.1:$PORT"

REPO_ROOT="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || exit 1
REPO_NAME="$(basename "$REPO_ROOT")"

# Same origin -> first-remote -> repo-root resolution the SessionStart hook
# uses. It must match exactly, or a repo without an `origin` compares unequal
# against its own namespace.
REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE" ]; then
  FIRST_REMOTE="$(git -C "$REPO_ROOT" remote 2>/dev/null | head -1 || true)"
  [ -n "$FIRST_REMOTE" ] && REMOTE="$(git -C "$REPO_ROOT" remote get-url "$FIRST_REMOTE" 2>/dev/null || true)"
fi
[ -n "$REMOTE" ] || REMOTE="$REPO_ROOT"

urlencode_path() {
  local path="$1" seg out=()
  local IFS='/'
  read -ra parts <<< "$path"
  for seg in "${parts[@]}"; do
    out+=("$(jq -rn --arg s "$seg" '$s|@uri')")
  done
  local IFS='/'
  echo "${out[*]}"
}

api_get_to() { # api_get_to <vault-path> <dest-file>
  curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
    -H "Accept: text/markdown" -o "$2" "$BASE/vault/$(urlencode_path "$1")"
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- namespace exists, and belongs to this repo -----------------------------
api_get_to "synapse/$REPO_NAME/Index.md" "$WORK/Index.md" || exit 1
EXISTING_REMOTE="$(grep -m1 '^remote:' "$WORK/Index.md" | sed -e 's/^remote: *//' -e 's/^"//' -e 's/"$//')"
[ "$EXISTING_REMOTE" = "$REMOTE" ] || exit 1

api_get_to "synapse/$REPO_NAME/_index.json" "$WORK/_index.json" || exit 1
jq -e . "$WORK/_index.json" >/dev/null 2>&1 || exit 1

# Node list comes from _index.json's values -- authoritative for which nodes
# exist, and already in hand, so no directory listing is needed.
jq -r 'to_entries | map(select(.key != "_unassigned")) | map(.value[]) | unique | .[]' \
  "$WORK/_index.json" > "$WORK/nodes.txt" 2>/dev/null || exit 1

# --- per node: recompute the digest over its own recorded sources -----------
# The node's `sources` is the authority on what it covers, not _index.json --
# verifying against the index instead would mask node/index drift, and would
# report a false mismatch whenever the two disagree for an unrelated reason.
extract_source_paths() { # frontmatter `  - path: X` lines, in file order
  awk '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "")
      print
    }
  ' "$1"
}

while IFS= read -r node; do
  [ -n "$node" ] || continue
  NODE_FILE="$WORK/node.md"
  if ! api_get_to "synapse/$REPO_NAME/$node" "$NODE_FILE"; then
    printf '%s\tnode file missing from the vault\n' "${node%.md}"
    continue
  fi

  STORED="$(grep -m1 '^sources_digest:' "$NODE_FILE" | sed -e 's/^sources_digest: *//' -e 's/^"//' -e 's/"$//')"
  if [ -z "$STORED" ]; then
    printf '%s\tno sources_digest (built before the digest existed)\n' "${node%.md}"
    continue
  fi

  extract_source_paths "$NODE_FILE" > "$WORK/paths.txt"
  if [ ! -s "$WORK/paths.txt" ]; then
    printf '%s\tno sources listed\n' "${node%.md}"
    continue
  fi

  # A recorded file that no longer exists is staleness, and `git hash-object`
  # would fail the whole batch on it -- so check first and report by name.
  MISSING="$(while IFS= read -r p; do
    [ -f "$REPO_ROOT/$p" ] || printf '%s ' "$p"
  done < "$WORK/paths.txt")"
  if [ -n "$MISSING" ]; then
    printf '%s\tsource files gone: %s\n' "${node%.md}" "${MISSING% }"
    continue
  fi

  # One fork for all of this node's files.
  HASHES="$(cd "$REPO_ROOT" && git hash-object --stdin-paths < "$WORK/paths.txt" 2>/dev/null)"
  [ -n "$HASHES" ] || { printf '%s\thashing failed\n' "${node%.md}"; continue; }

  # Digest definition, pinned in /synapse-init: sha256 over the LC_ALL=C
  # sorted "path:hash" lines, newline-joined, no trailing newline.
  # $(...) strips trailing newlines, and printf '%s' adds none back -- so the
  # hashed bytes are exactly the joined lines with no terminator.
  JOINED="$(paste -d: "$WORK/paths.txt" <(printf '%s\n' "$HASHES") | LC_ALL=C sort)"
  CURRENT="$(printf '%s' "$JOINED" | sha256)"

  [ "$CURRENT" = "$STORED" ] || printf '%s\tcontent changed\n' "${node%.md}"
done < "$WORK/nodes.txt"

exit 0
