#!/bin/bash
# PostToolUse hook (Write|Edit|MultiEdit): Synapse Tier 1 staleness flagging.
# A hook is a plain script, not an agent turn -- it already knows with
# certainty which file just changed, so this is pure bookkeeping (no
# git-hash verification, that's Tier 2 at read time). Talks to the Obsidian
# Local REST API directly rather than through the mcp__obsidian__ tools,
# same reasoning as synapse-db-sync.sh.
set -euo pipefail

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
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

# A namespace is keyed by directory basename, so two unrelated repos sharing
# one would otherwise write into each other's graph. The SessionStart hook and
# synapse-query.sh both refuse on a remote mismatch; this is the write side of
# the same check, and it must resolve the remote *identically* to them --
# origin, then the first listed remote, then the repo root for a repo with no
# remote at all. A different chain here means one component refuses where
# another proceeds, which is worse than either behaviour on its own.
REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE" ]; then
  FIRST_REMOTE="$(git -C "$REPO_ROOT" remote 2>/dev/null | head -1 || true)"
  [ -n "$FIRST_REMOTE" ] && REMOTE="$(git -C "$REPO_ROOT" remote get-url "$FIRST_REMOTE" 2>/dev/null || true)"
fi
[ -n "$REMOTE" ] || REMOTE="$REPO_ROOT"

# Read the namespace's own Index.md from disk rather than over REST: this is a
# read, $VAULT is already known and checked above, and it keeps the guard ahead
# of any HTTP at all. A namespace with no readable `remote:` line counts as a
# mismatch, not as a match against the empty string -- absent provenance is not
# permission to write.
# Note the `|| true` and the `if` wrapper: under `set -euo pipefail` a grep
# that matches nothing fails the pipeline and would kill the hook outright
# instead of skipping quietly. A hook erroring out is worse than the write it
# was guarding against.
NS_INDEX="$VAULT/synapse/$REPO_NAME/Index.md"
NS_REMOTE=""
if [ -f "$NS_INDEX" ]; then
  NS_REMOTE="$(grep -m1 '^remote:' "$NS_INDEX" 2>/dev/null \
    | sed -e 's/^remote: *//' -e 's/^"//' -e 's/"$//' || true)"
fi
if [ -z "$NS_REMOTE" ] || [ "$NS_REMOTE" != "$REMOTE" ]; then
  exit 0
fi

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

INDEX_FILE="$VAULT/$INDEX_VAULT_PATH"

# Read the index from disk, not over the API. It is a derived, machine-only file
# that nothing but these scripts writes, and every write below still goes through
# the API, so Obsidian's view and the vault's git history stay correct.
#
# The reason is cost, and it is the one cost in Synapse that scales with the repo
# rather than the node count. On a 125k-file repo this file is 27 MB; fetching it
# over HTTPS to answer a single key lookup dominated the hook at ~3.1s, paid on
# every Write/Edit/MultiEdit. From disk the same read is ~0.03s.
#
# A missing file is the "no namespace" case: /synapse-init has not been run here.
# That check replaces the old HTTP-status test, and is exact rather than
# approximate -- the API returns a 404 whose *body is valid JSON*
# (`{"message":"Not Found",...}`), so reading the status was the only way to tell
# an absent index from a real one. On disk the question is just whether the file
# is there.
[ -f "$INDEX_FILE" ] || exit 0

NODES="$(jq -r --arg rel "$REL" '.[$rel] // [] | .[]' "$INDEX_FILE" 2>/dev/null || true)"

if [ -z "$NODES" ]; then
  # Genuinely new file, not yet claimed by any node -- queue it for the
  # _unassigned sweep (see /synapse-init's "Re-running on an initialized
  # project" and the Tier 2 read-time procedure).
  UPDATED="$(jq --arg rel "$REL" '
    .["_unassigned"] = ((.["_unassigned"] // []) + [$rel] | unique)
  ' "$INDEX_FILE" 2>/dev/null || true)"
  # The upfront `jq -e .` validation is gone (it duplicated a status check that
  # disk existence now answers exactly), so this is where a malformed index has to
  # be caught: jq would print nothing, and PUTting that would replace a 27 MB
  # index with an empty body. Refuse to write rather than destroy it.
  [ -n "$UPDATED" ] || exit 0
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

# --- opportunistic correction --------------------------------------------
# Flagging `stale: true` says "something under this node changed"; it never says
# the prose is now wrong, and nothing ever goes back to check. This does, but
# only where the edit landed on evidence the node explicitly cites: the file its
# `crux` was sliced from, or a range it records in `grounded_in`. That narrowness
# is the whole design. Nudging on any edit to any of a node's files would fire
# constantly and be tuned out within a day; nudging only when cited evidence
# actually stopped matching fires rarely and means something every time.
#
# It is also free: this is the one moment the model has certainly just read the
# code, so no re-reading is asked for. Correctness accrues along the paths that
# get worked in, and dormant subsystems stay as vague as they were -- which is
# the right trade, since nobody is touching them.
#
# Kept dependency-free and self-contained, like the rest of this hook. The
# grounded_in parser mirrors synapse-query.sh's extract_grounded_in; the tests
# assert on the behaviour rather than the duplication.
if command -v shasum >/dev/null; then
  sha256() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null; then
  sha256() { sha256sum | cut -d' ' -f1; }
else
  sha256() { echo unavailable; }
fi

FINDINGS="$(mktemp "${TMPDIR:-/tmp}/synapse-hook.XXXXXX")"
trap 'rm -f "$FINDINGS"' EXIT

# Reports cited evidence in the edited file that no longer matches what was
# recorded. Silent when it still matches, and silent for a node that cites
# nothing from this file at all.
check_cited_evidence() { # check_cited_evidence <node-file> <node-name>
  local nf="$1" name="${2%.md}" cpath clines cstart cend stored actual

  cpath="$(grep -m1 '^crux_path:' "$nf" | sed -e 's/^crux_path: *//' || true)"
  if [ "$cpath" = "$REL" ]; then
    clines="$(grep -m1 '^crux_lines:' "$nf" | sed -e 's/^crux_lines: *//' -e 's/"//g' || true)"
    cstart="${clines%%-*}"; cend="${clines##*-}"
    if [ -n "$cstart" ] && [ -n "$cend" ]; then
      # No digest is stored for the crux -- the sliced text lives in the note, so
      # compare the note's own fenced copy against the file as it is now.
      stored="$(awk '/^```/ { f = !f; next } f { print }' "$nf" | sha256)"
      actual="$(sed -n "${cstart},${cend}p" "$FILE" | sha256)"
      [ "$stored" = "$actual" ] || \
        printf '%s\tcrux (%s:%s)\n' "$name" "$REL" "$clines" >> "$FINDINGS"
    fi
  fi

  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { exit }
    !fm { next }
    /^grounded_in:[[:space:]]*$/ { g = 1; next }
    g && /^[^[:space:]]/ { g = 0 }
    g && /^  - path:/ { p = $0; sub(/^  - path:[[:space:]]*/, "", p); next }
    g && /^    lines:/ { l = $0; sub(/^    lines:[[:space:]]*/, "", l); gsub(/"/, "", l); next }
    g && /^    digest:/ { d = $0; sub(/^    digest:[[:space:]]*/, "", d)
                          if (p != "" && l != "" && d != "") print p "\t" l "\t" d
                          p = ""; l = ""; d = ""; next }
  ' "$nf" > "$nf.grounded" || true

  while IFS="$(printf '\t')" read -r gp gl gd; do
    [ "$gp" = "$REL" ] || continue
    actual="$(sed -n "${gl%%-*},${gl##*-}p" "$FILE" | sha256)"
    [ "$actual" = "$gd" ] || \
      printf '%s\tgrounding (%s:%s)\n' "$name" "$REL" "$gl" >> "$FINDINGS"
  done < "$nf.grounded"
  rm -f "$nf.grounded"
}

while IFS= read -r node; do
  [ -n "$node" ] || continue
  NODE_URL="$BASE/vault/$(urlencode_path "synapse/$REPO_NAME/$node")"

  # Explicit templates: macOS `mktemp` with no template ignores TMPDIR.
  ORIG="$(mktemp "${TMPDIR:-/tmp}/synapse-hook.XXXXXX")"
  NEXT="$(mktemp "${TMPDIR:-/tmp}/synapse-hook.XXXXXX")"
  if ! curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
        -H "Accept: text/markdown" -o "$ORIG" "$NODE_URL"; then
    rm -f "$ORIG" "$NEXT"
    continue
  fi

  # Before the staleness write, and regardless of whether it happens: a node
  # that is already flagged stale can still be citing evidence this edit just
  # invalidated, and skipping the check there would hide exactly the case where
  # the prose has had the longest to go wrong.
  check_cited_evidence "$ORIG" "$node"

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

# Nothing to say unless cited evidence actually stopped matching. Silence is the
# common case by design -- an edit to a file a node merely covers gets flagged
# stale and produces no output at all.
[ -s "$FINDINGS" ] || exit 0

# `additionalContext` rather than `decision: block`: this is information for the
# next turn, not a reason to stop. Same shape as synapse-stop-nudge.sh.
jq -Rn --rawfile findings "$FINDINGS" '
  ($findings | rtrimstr("\n") | split("\n")
    | map(split("\t") | "  - " + .[0] + " — " + .[1]) | join("\n")) as $list
  | {
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: (
          "You just edited a file that these Synapse nodes cite as evidence, and the cited range no longer matches what was recorded:\n"
          + $list
          + "\n\nYou have the code in front of you right now, so checking is nearly free — this is the one moment correcting a node costs nothing extra. If a sentence in the node is now wrong, fix that sentence and re-point the evidence, following the synapse-node skill: recover the prose with `synapse-query.sh body`, re-emit the crux and grounded_in directives, and write it back with synapse-write-node.sh.\n\n"
          + "Keep it incidental. Correct only what this edit actually contradicts. Do NOT re-read the node'"'"'s other sources, do not verify its remaining claims, and do not start a sweep — that is /synapse-rebuild'"'"'s job, and turning this into one is how a cheap habit becomes an expensive one. If the prose still holds despite the range moving, just re-point it and move on."
        )
      }
    }'
