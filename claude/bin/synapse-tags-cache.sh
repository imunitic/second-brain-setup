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
#   Tagging is BATCHED, one `synapse-tags.sh --paths` invocation per chunk
#   rather than one per file: CLI startup and grammar load are nearly all of
#   the per-file cost, measured at 0.076s for 200 files in one invocation
#   against 2.543s for 200 invocations across 12 workers. A hub node's 800
#   sources are a handful of calls, not 800.
#
#   Parallelism: xargs -P over the chunks, capped at nproc/sysctl -n hw.ncpu
#   (falls back to 4). Each worker writes its own raw batch output to a private
#   temp file; a single sequential jq pass afterward attributes those to paths
#   and merges them into the cache. No worker ever writes the shared cache file
#   directly.
#
#   A file with no usable grammar is still recorded, as `unsupported: true`
#   with empty tags, so it isn't silently re-attempted on every call. That is
#   a distinct outcome from "checked, symbol not present" -- callers must
#   report it as such, never as a plain non-match. In batch output the two are
#   told apart by shape: an unparseable file is absent entirely, while one that
#   parsed to nothing still gets its path line.
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
need_n="$(LC_ALL=C wc -l < "$WORK/needs-tagging.tsv" | tr -d ' ')"

# One invocation per CHUNK, not per file. CLI startup and grammar load are
# nearly all of the per-file cost -- 200 files measured 0.076s batched against
# 2.543s as 200 invocations across 12 workers -- so a hub node's 800 sources
# went from a per-file loop to a handful of calls. The floor keeps a small node
# from being split into chunks whose startup outweighs their work.
CHUNK=$(( (need_n + N - 1) / N ))
[ "$CHUNK" -ge 200 ] || CHUNK=200
mkdir -p "$WORK/chunks" "$WORK/out"
cut -f1 "$WORK/needs-tagging.tsv" > "$WORK/needs-paths.txt"
split -l "$CHUNK" "$WORK/needs-paths.txt" "$WORK/chunks/c."

# Generated rather than an exported shell function: `export -f` is a bash
# builtin that silently does nothing when the surrounding shell is zsh, and the
# symptom is a suspiciously fast run that produced nothing.
#
# The batch runs from $REPO_ROOT with repo-relative paths, so the path lines
# tree-sitter echoes back ARE the cache keys -- no re-derivation, and nothing
# for a path containing a space to be split on. That is what the previous
# `xargs -L 1` shape got wrong: xargs word-splits on spaces as well as tabs, so
# such a path shifted every field, tagged the wrong file, and wrote its result
# where the merge never looked. The entry silently never entered the cache and
# was re-attempted on every subsequent call.
cat > "$WORK/worker.sh" <<'WORKER'
#!/bin/bash
# worker.sh <chunk> <out-dir> <repo-root> <tags-sh>
chunk="$1"; outdir="$2"; repo="$3"; tags_sh="$4"
cd "$repo" || exit 0
"$tags_sh" --paths "$chunk" 2>/dev/null > "$outdir/$(basename "$chunk").tags"
WORKER
chmod +x "$WORK/worker.sh"

find "$WORK/chunks" -type f -name 'c.*' -print0 \
  | xargs -0 -P "$N" -I {} "$WORK/worker.sh" {} "$WORK/out" "$REPO_ROOT" "$TAGS_SH"

cat "$WORK"/out/*.tags > "$WORK/all.tags" 2>/dev/null || : > "$WORK/all.tags"

# --- sequential join: ONE jq pass attributes the batch and merges it --------
# Batch output is attributable by shape: an unindented line is a path, and the
# tab-indented lines under it are that path's tags. A file tree-sitter has no
# grammar for is absent from the output entirely, whereas one it parsed and
# found nothing in still gets its path line -- verified against the real CLI,
# and the distinction is the whole basis for `unsupported` here. Recording it
# is what stops an unparseable file being re-attempted on every single call.
#
# jq does the attribution rather than a shell loop for the usual reason: a loop
# would be one process per path, which is the cost the batching just removed.
jq --rawfile tags "$WORK/all.tags" --rawfile req "$WORK/needs-tagging.tsv" '
  . as $base
  | ($tags | split("\n")
     | reduce .[] as $l ({cur: null, acc: {}};
         if $l == "" then .
         elif ($l | startswith("\t")) then
           # The indent is batch-mode framing, not content: single-file output
           # has no leading tab, and consumers split on \t and read field 1 as
           # the symbol name. Keeping it would make field 1 empty on every
           # line, so `synapse-query.sh symbol` would match nothing at all and
           # report it as a clean not-found. Stripped here so a cache entry is
           # byte-identical to what the per-file form recorded.
           ($l | ltrimstr("\t")) as $t
           | if .cur == null then .
             else .acc[.cur] += (if .acc[.cur] == "" then $t else "\n" + $t end)
             end
         else .cur = $l | .acc[$l] = (.acc[$l] // "")
         end)
     | .acc) as $tagged
  | reduce ($req | split("\n"))[] as $line ($base;
      ($line | split("\t")) as $f
      | if ($f | length) < 2 or $f[0] == "" then .
        else .[$f[0]] = { hash: $f[1],
                          tags: ($tagged[$f[0]] // ""),
                          unsupported: ($tagged | has($f[0]) | not) }
        end)
' "$CACHE" > "$WORK/merged.json" || exit 1
mv "$WORK/merged.json" "$CACHE"
