#!/bin/bash
# Keeps a project's synapse-tags.sh output cache current for a given set of
# files, re-tagging only what changed and doing so in parallel when several
# files need it. Shared by node build/regeneration (piggybacked on the same
# per-file hash comparison it already performs) and synapse-query.sh's
# `symbol` subcommand (lazy backfill on a cache miss). See docs/synapse-graph.md's
# "Exact-symbol lookup" section for the full design and the measured cost of
# a cold, fully-uncached run.
#
# Usage: synapse-tags-cache.sh --repo-root <path> --cache <_tags_cache.json path> --paths <file>
#   --paths  file of repo-relative path<TAB>current-git-hash lines, one per
#            file the caller wants current in the cache (a node's `sources`,
#            typically -- the caller already has both path and hash).
#
#   Parallelism: xargs -P, capped at nproc/sysctl -n hw.ncpu (falls back to 4),
#   fed NUL-terminated records so paths containing spaces survive intact.
#   Every worker tags one file and writes its own result to a private temp
#   file; a single sequential step afterward merges those into the cache in
#   one pass. No worker ever writes the shared cache file directly.
#
#   A file synapse-tags.sh can't check (no grammar, no tree-sitter, no C
#   compiler -- its own exit 1/2) is still recorded, as `unsupported: true`
#   with empty tags, so it isn't silently re-attempted on every call. That is
#   a distinct outcome from "checked, symbol not present" -- callers must
#   report it as such, never as a plain non-match.
#
# Exit codes:
#   0 - cache is current for every requested path (already-current paths need
#       no work; this is also the outcome when nothing needed tagging at all)
#   1 - usage error, missing dependency, or the cache could not be read/written
set -uo pipefail

usage() {
  awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
  exit 1
}

REPO_ROOT=""
CACHE=""
PATHS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 || usage ;;
    --cache) CACHE="${2:-}"; shift 2 || usage ;;
    --paths) PATHS_FILE="${2:-}"; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$REPO_ROOT" ] && [ -n "$CACHE" ] && [ -n "$PATHS_FILE" ] || usage
[ -d "$REPO_ROOT" ] || exit 1
[ -f "$PATHS_FILE" ] || exit 1

command -v jq >/dev/null || exit 1

TAGS_SH="$HOME/.claude/bin/synapse-tags.sh"
[ -x "$TAGS_SH" ] || exit 1

mkdir -p "$(dirname "$CACHE")" || exit 1
[ -f "$CACHE" ] || printf '{}' > "$CACHE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/synapse-tags-cache.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- diff: which requested path:hash pairs the cache doesn't already have --
# One jq parse of the cache (however big), then a plain sorted-text `comm` --
# not a jq lookup per requested path, which would re-parse the whole cache
# once per file and dominate cost on a large project.
jq -r 'to_entries[] | "\(.key)\t\(.value.hash)"' "$CACHE" 2>/dev/null | LC_ALL=C sort > "$WORK/cached.tsv" \
  || { echo "synapse-tags-cache: unreadable cache: $CACHE" >&2; exit 1; }
LC_ALL=C sort -u "$PATHS_FILE" > "$WORK/requested.tsv"
LC_ALL=C comm -23 "$WORK/requested.tsv" "$WORK/cached.tsv" > "$WORK/needs-tagging.tsv"

[ -s "$WORK/needs-tagging.tsv" ] || exit 0

N="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# One job per file: tag it, write {path, hash, tags, unsupported} to a
# private result file. Exported so xargs's child `bash -c` shells see it.
tag_one() { # tag_one <path> <hash> <outfile>
  local path="$1" hash="$2" outfile="$3" tags rc unsupported
  tags="$("$HOME/.claude/bin/synapse-tags.sh" "$REPO_ROOT/$path" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && unsupported=false || unsupported=true
  jq -n --arg path "$path" --arg hash "$hash" --arg tags "$tags" --argjson unsupported "$unsupported" \
    '{path: $path, hash: $hash, tags: $tags, unsupported: $unsupported}' > "$outfile"
}
export -f tag_one
export REPO_ROOT

# Splits one job record and hands its fields to tag_one. A separate function
# purely so the xargs child below stays free of tab-quoting gymnastics.
tag_record() { # tag_record <path TAB hash TAB outfile>
  local path hash outfile
  IFS=$'\t' read -r path hash outfile <<< "$1"
  tag_one "$path" "$hash" "$outfile"
}
export -f tag_record

# NUL-terminated records, one whole record per child (`-0 -n 1`), split on the
# tab inside the child -- NOT `-L 1` with three positional args. xargs word-
# splits on blanks, tabs *and spaces* alike, so a source path containing a
# space would shift every field: the child would tag the wrong path and write
# its result to a stray file outside $WORK/results, which the merge below then
# skips. That path would never enter the cache, so `synapse-query.sh symbol`
# would report it as "not checked" and re-attempt it on every single call.
mkdir -p "$WORK/results"
i=0
: > "$WORK/jobs.nul"
while IFS=$'\t' read -r path hash; do
  i=$((i + 1))
  printf '%s\t%s\t%s/results/%s.json\0' "$path" "$hash" "$WORK" "$i" >> "$WORK/jobs.nul"
done < "$WORK/needs-tagging.tsv"

xargs -0 -P "$N" -n 1 bash -c 'tag_record "$1"' _ < "$WORK/jobs.nul"

# --- sequential join: one jq pass merges every result into the cache -------
# `-s` slurps the cache plus every result file into one array: .[0] is the
# cache object, .[1:] are the per-file results. A single process, not one
# jq spawn per changed file -- that loop shape is what the parallel tagging
# step above exists to avoid, and re-introducing it here for the merge would
# undercut the same thing.
shopt -s nullglob
result_files=("$WORK"/results/*.json)
[ ${#result_files[@]} -gt 0 ] || exit 0
jq -s '
  (.[0]) as $base |
  (.[1:] | map({(.path): {hash: .hash, tags: .tags, unsupported: .unsupported}}) | add) as $new |
  $base * $new
' "$CACHE" "${result_files[@]}" > "$WORK/merged.json" || exit 1
mv "$WORK/merged.json" "$CACHE"
