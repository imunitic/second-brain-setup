#!/bin/bash
# Reduces a whole repository to its symbol vocabulary, grouped by directory:
# `group <TAB> word <TAB> count`. Evidence for the clustering step of
# /synapse-init, so that deciding what a subsystem is about costs symbol names
# rather than source lines. See docs/synapse-graph.md's "Orientation from
# vocabulary" section.
#
# Usage: synapse-vocab.sh [--repo <path>] [--depth N] [--chunk N] [--out <dir>]
#   --repo   default: the git toplevel containing $PWD.
#   --depth  directory levels that make a group, default 2 (`src/main` from
#            `src/main/java/Foo.java`). A path shallower than that groups by
#            whatever prefix it has; a repo-root file groups as `(repo root)`.
#   --chunk  files per tree-sitter invocation, default: one chunk per core,
#            floor 500. Only a parallelism knob -- see below.
#   --out    default: $SYNAPSE_WORK_DIR, i.e. ~/.claude/synapse-work/{repo}@{branch}/.
#
# Writes  <out>/groupwords.tsv   group <TAB> word <TAB> count, group then count desc
#         <out>/counts.tsv       group <TAB> file count, count desc
#
# Prints groups / files / code files / pairs on stderr, so a repo that yielded
# no vocabulary is a number rather than an empty file nobody looked at.
#
# WHY THIS IS AFFORDABLE. Tagging goes through `synapse-tags.sh --paths`, one
# invocation per chunk, because CLI startup and grammar load are nearly all of
# the per-file cost: 200 files measured 0.076s batched against 2.543s as 200
# invocations across 12 workers. The whole of syrius3 (125,351 files, 98k of
# them code) takes ~51s. Chunking exists only to use more than one core; it is
# not what makes this cheap.
#
# RAW TAGS ARE NEVER STORED. Each worker pipes `synapse-tags.sh` straight into
# the word reduction and keeps only `group <TAB> word`. The tags themselves are
# ~942 MB on syrius3 against 6.9 MB of vocabulary, so writing them out first
# would cost more disk than the entire graph.
#
# EVERY TRANSFORM IS awk, NOT sed. `sed` works on whole lines, so a character
# class meant for the symbol field also mangles the group key and the tab
# between them -- and BSD `sed` reads `\t` inside a bracket expression as a
# literal `t`, which silently destroys the field separator rather than erroring.
# Everything runs under LC_ALL=C for the same class of reason: macOS `awk`
# aborts mid-stream on Latin-1 bytes, which real repos contain.
#
# Word splitting matches the identifier conventions, not English: `getUserName`
# gives get/user/name, `user_name` gives user/name, and a run of capitals stays
# with what follows it (`HTTPServer` is one word). Words shorter than 4
# characters, pure digits, and anything in ~/.claude/synapse-prompt-stopwords.conf
# are dropped -- the same list the prompt tokenizer uses, deliberately, because
# two stopword lists that disagree is how two mechanisms start giving different
# answers.
#
# Exit codes:
#   0 - ran. An EMPTY groupwords.tsv is a legitimate outcome (no file had a
#       usable grammar) and the caller must test for it: that is the signal to
#       fall back to `synapse-orientation`, not an error to report.
#   1 - could not run (not a git repo, no synapse-tags.sh, no work dir)
#   2 - usage error
set -uo pipefail

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

REPO=""
DEPTH=2
CHUNK=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)  REPO="${2:-}";  shift 2 || usage ;;
        --depth) DEPTH="${2:-}"; shift 2 || usage ;;
        --chunk) CHUNK="${2:-}"; shift 2 || usage ;;
        --out)   OUT="${2:-}";   shift 2 || usage ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
case "$DEPTH" in ''|*[!0-9]*) usage ;; esac
[ "$DEPTH" -ge 1 ] || usage
[ -z "$CHUNK" ] || case "$CHUNK" in ''|*[!0-9]*) usage ;; esac

command -v git >/dev/null || { echo "synapse-vocab: git required" >&2; exit 1; }
if [ -n "$REPO" ]; then
    REPO_ROOT="$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || { echo "synapse-vocab: not inside a git repo" >&2; exit 1; }

TAGS_SH="$HOME/.claude/bin/synapse-tags.sh"
[ -x "$TAGS_SH" ] || {
    echo "synapse-vocab: synapse-tags.sh not installed (run setup.sh) -- use synapse-orientation instead" >&2
    exit 1; }

if [ -z "$OUT" ]; then
    # "{repo}@{branch}", not a bare repo name -- see synapse-identity.sh.
    # shellcheck source=/dev/null
    . "$HOME/.claude/bin/synapse-identity.sh" 2>/dev/null || {
        echo "synapse-vocab: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
    REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1
    OUT="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
fi
mkdir -p "$OUT" || { echo "synapse-vocab: cannot write $OUT" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/synapse-vocab.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/chunks" "$W/words"

# Languages with a tree-sitter grammar worth having. Not the same question as
# "what belongs in the graph": a file with no grammar still gets covered by a
# node and still flags staleness, it just contributes no vocabulary.
CODE_RE='\.(java|kt|kts|scala|groovy|gradle|js|jsx|ts|tsx|py|go|rs|c|cc|cpp|h|hpp|cs|rb|php|swift|sh|bash)$'

# Machine output that happens to end in a code extension. The only part of
# synapse-build-lists.sh's exclusions CODE_RE does not already subsume -- its
# binary and lockfile lists are all non-code extensions, so repeating them here
# would be two copies of one rule with nothing to gain.
GENERATED_RE='\.min\.(js|css)$|\.(js|css|ts)\.map$'

# The user's own exclusions, honoured because vendored and generated trees
# would otherwise dominate the vocabulary of whatever group they sit in. Same
# two knobs synapse-build-lists.sh reads, so a path excluded from the graph is
# also excluded from the evidence used to design the graph. `^$` when empty --
# an empty alternative in an ERE matches every line.
IGNORE_CONF="$HOME/.claude/synapse-ignore-files.conf"
EXTRA_RE="${SYNAPSE_EXTRA_EXCLUDE_RE:-}"
if [ -f "$IGNORE_CONF" ]; then
    while IFS= read -r pat; do
        pat="${pat%%#*}"
        pat="$(printf '%s' "$pat" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }')"
        [ -n "$pat" ] || continue
        EXTRA_RE="${EXTRA_RE:+$EXTRA_RE|}$pat"
    done < "$IGNORE_CONF"
fi
[ -n "$EXTRA_RE" ] || EXTRA_RE='^$'

cd "$REPO_ROOT" || exit 1
git ls-files > "$W/all.txt" 2>/dev/null || {
    echo "synapse-vocab: git ls-files failed in $REPO_ROOT" >&2; exit 1; }
LC_ALL=C grep -Ev "$EXTRA_RE" "$W/all.txt" > "$W/kept.txt" || : > "$W/kept.txt"
LC_ALL=C grep -E "$CODE_RE" "$W/kept.txt" \
    | LC_ALL=C grep -Ev "$GENERATED_RE" > "$W/code.txt" || : > "$W/code.txt"

# The grouping rule, defined once and textually shared by both output passes:
# counts.tsv and groupwords.tsv keyed differently is the failure that makes a
# group look like it has vocabulary but no files, or the reverse.
GROUP_FN='
function group_of(path,   n, seg, lim, k, i) {
  n = split(path, seg, "/")
  lim = (n - 1 < DEPTH) ? n - 1 : DEPTH
  if (lim < 1) return "(repo root)"
  k = seg[1]
  for (i = 2; i <= lim; i++) k = k "/" seg[i]
  return k
}'

LC_ALL=C awk -v DEPTH="$DEPTH" "$GROUP_FN"'
  { c[group_of($0)]++ }
  END { for (k in c) print k "\t" c[k] }
' "$W/kept.txt" | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k1,1 > "$OUT/counts.tsv"

# The tokenizer's own list, cleaned once here rather than per worker: comments
# and blanks stripped, lowercased to match the lowercased words.
STOP_CONF="$HOME/.claude/synapse-prompt-stopwords.conf"
if [ -f "$STOP_CONF" ]; then
    LC_ALL=C awk '{ sub(/^[[:space:]]+/, ""); if ($0 == "" || $0 ~ /^#/) next; print tolower($0) }' \
        "$STOP_CONF" | LC_ALL=C sort -u > "$W/stop.txt"
else
    : > "$W/stop.txt"
fi

code_n="$(LC_ALL=C wc -l < "$W/code.txt" | tr -d ' ')"
if [ "$code_n" -eq 0 ]; then
    : > "$OUT/groupwords.tsv"
    echo "synapse-vocab: no files with a supported grammar -- use synapse-orientation instead" >&2
    exit 0
fi

NP="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
if [ -z "$CHUNK" ]; then
    CHUNK=$(( (code_n + NP - 1) / NP ))
    [ "$CHUNK" -ge 500 ] || CHUNK=500
fi
split -l "$CHUNK" "$W/code.txt" "$W/chunks/c."

# One worker per chunk, generated rather than an exported shell function: this
# script's own shell is bash, but `export -f` is a bash builtin that silently
# does nothing when the surrounding shell is zsh, and the symptom is a
# suspiciously fast run producing nothing rather than an error.
cat > "$W/worker.sh" <<'WORKER'
#!/bin/bash
# worker.sh <chunk> <words-dir> <depth> <stopwords> <tags-sh>
# Derives its own output name so the caller can pass one fixed directory: with
# `xargs -I {}` the placeholder is substituted into every argument, so building
# the output path outside would splice the chunk's full path into it.
chunk="$1"; words="$2"; depth="$3"; stop="$4"; tags_sh="$5"
out="$words/$(basename "$chunk").tsv"
"$tags_sh" --paths "$chunk" 2>"$out.err" \
  | LC_ALL=C awk -F'\t' -v DEPTH="$depth" -v STOP="$stop" '
      function group_of(path,   n, seg, lim, k, i) {
        n = split(path, seg, "/")
        lim = (n - 1 < DEPTH) ? n - 1 : DEPTH
        if (lim < 1) return "(repo root)"
        k = seg[1]
        for (i = 2; i <= lim; i++) k = k "/" seg[i]
        return k
      }
      BEGIN { while ((getline s < STOP) > 0) stopw[s] }
      # Unindented line: a path. Every tab-indented line after it holds one tag
      # for that path, and field 2 of such a line is the symbol name.
      /^[^\t]/ { g = group_of($0); next }
      g == "" { next }
      {
        s = $2
        while (match(s, /[A-Z]+[a-z0-9]*|[a-z0-9]+/)) {
          w = tolower(substr(s, RSTART, RLENGTH))
          s = substr(s, RSTART + RLENGTH)
          if (length(w) < 4) continue
          if (w ~ /^[0-9]+$/) continue
          if (w in stopw) continue
          print g "\t" w
        }
      }
    ' > "$out"
WORKER
chmod +x "$W/worker.sh"

find "$W/chunks" -type f -name 'c.*' -print0 \
    | xargs -0 -P "$NP" -I {} "$W/worker.sh" {} "$W/words" "$DEPTH" "$W/stop.txt" "$TAGS_SH"

# Counted in awk, not `sort | uniq -c`: uniq's count column is space-separated,
# so a group key containing a space would shift every field downstream. The
# whole line is the key here, tabs included, so nothing needs re-splitting.
: > "$OUT/groupwords.tsv"
word_files=("$W"/words/*.tsv)
if [ -e "${word_files[0]}" ]; then
    LC_ALL=C awk '{ c[$0]++ } END { for (k in c) print k "\t" c[k] }' "${word_files[@]}" \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k3,3nr > "$OUT/groupwords.tsv"
fi

# One line per missing grammar for the whole run, not one per chunk: every
# chunk containing a `.foo` file reports it, and a caller can act on the
# extension exactly once.
#
# `>&2` alone, NOT `2>/dev/null >&2`: redirections apply left to right, so that
# order points fd2 at /dev/null and then copies it into fd1, sending the
# warnings themselves to /dev/null. The glob is guarded instead, which is what
# the discarded stderr was covering for.
err_files=("$W"/words/*.err)
if [ -e "${err_files[0]}" ]; then
    LC_ALL=C sort -u "${err_files[@]}" >&2
fi

printf 'synapse-vocab: groups %s, files %s, code %s, pairs %s -> %s\n' \
    "$(LC_ALL=C wc -l < "$OUT/counts.tsv" | tr -d ' ')" \
    "$(LC_ALL=C wc -l < "$W/kept.txt" | tr -d ' ')" \
    "$code_n" \
    "$(LC_ALL=C wc -l < "$OUT/groupwords.tsv" | tr -d ' ')" \
    "$OUT" >&2
exit 0
