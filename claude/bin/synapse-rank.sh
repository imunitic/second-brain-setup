#!/bin/bash
# Ranks a node's sources by how much they are worth READING when authoring its
# prose. Decides reading order only: `sources` stays exhaustive, so coverage,
# staleness and vault search are all unaffected by anything here. See
# docs/synapse-graph.md's "Orientation from vocabulary" section.
#
# Usage: synapse-rank.sh --sources <file> [--repo <path>] [--top N] [--tier T]
#                        [--pool summary|crux]
#   --sources  file of repo-relative paths, one per line -- a node's `sources`,
#              or synapse-build-lists.sh's lists/NN.txt.
#   --repo     default: the git toplevel containing $PWD.
#   --top      lines per tier, default 10. `--top 0` prints every ranked file.
#   --tier     restrict output to `code` or `dsl`. Default: both.
#   --pool     which half of the authoring job this is for, default `summary`
#              (which is the unrestricted behaviour). See below.
#
# THE TWO POOLS ARE NOT THE SAME SET OF FILES, and that is a measured result
# rather than tidiness.
#
#   summary   everything. A summary is made of NAMES, so it draws on test class
#             names and DSL consumer names as well as implementation -- both at
#             zero read cost, and both carrying domain concepts nothing else
#             surfaces. On a real node `Gegenpartei` and `Frist` came only from
#             test class names.
#
#   crux      implementation only, tests excluded, code tier only. A crux is
#             concentrated logic, and none of the seven `crux_path` values
#             recorded in a real namespace is a test. Density ranks tests high
#             for a structural reason -- many small `@Test` methods, each a
#             definition, in a small file -- so without this they would crowd
#             out the thing a crux is supposed to point at.
#
# What counts as a test is a path/filename heuristic, not a parse, and it is
# deliberately conservative about the boundary: `FooTest.java` is a test,
# `Latest.java` is not. Override the whole rule with $SYNAPSE_TEST_PATH_RE (one
# ERE) for a project that names tests some other way.
#
# Prints `tier <TAB> score <TAB> path`, ranked within each tier, code first.
# Counts per tier go to stderr, so a node whose files all scored zero is a
# number rather than an empty answer.
#
# THREE TIERS, because "relevant" means different things per kind of file.
#
#   code    definitions per KB. NOT raw definition counts: those rank generated
#           constant tables first, which is the opposite of useful. Normalising
#           by size moved a known crux from rank 17 to rank 7 of 574 on a real
#           node. Definitions specifically, not all tags -- a reference says the
#           file USES something, a definition says it DECLARES it, and a summary
#           is made of what a subsystem declares.
#
#   dsl     a declarative file carries little meaning on its own; the code that
#           consumes it carries the domain verbs. So the CONSUMER is what gets
#           ranked, scored by how many declarations it serves. Resolved by stem
#           plus module prefix, never by parsing.
#
#   ignore  everything else -- config, data, docs, generated output. Scored
#           zero and omitted from the ranking, still fully covered by `sources`.
#
# WHAT COUNTS AS DSL IS DERIVED, NOT LISTED. A non-code file is a declaration
# exactly when some code file in the same module has a stem starting with its
# own -- `Adresse.domvo` resolving to `Adresse.java`, `Kunde.gui` to
# `KundeController.java`. Shipping a list of extensions instead would have meant
# shipping one project's vocabulary (`.gui`, `.domvo`, `.bo`, `.paramvo`) as if
# it were universal, and this toolkit is meant to be language-agnostic with no
# per-repo curation.
#
# THE MODULE PREFIX IS LOAD-BEARING, not a tie-breaker. Generic stems -- the
# measured examples were `Adresse` and `NatPerson` -- match dozens of unrelated
# classes across a large repo, so a stem-only hop resolves to whichever one
# sorts first and is worse than no answer. Constraining to the declaration's own
# module is what makes the hop mean anything.
#
# Consumers are searched repo-wide rather than within `sources`: the code that
# uses a node's declarations is frequently the reason to read it, and is not
# always a file the node itself owns.
#
# Exit codes:
#   0 - ran. Empty output means nothing scored above zero, which for a node made
#       entirely of config is the correct answer, not a failure.
#   1 - could not run (not a git repo, unreadable sources, no synapse-tags.sh)
#   2 - usage error
set -uo pipefail

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

SOURCES=""
REPO=""
TOP=10
TIER=""
POOL="summary"
while [ $# -gt 0 ]; do
    case "$1" in
        --sources) SOURCES="${2:-}"; shift 2 || usage ;;
        --repo)    REPO="${2:-}";    shift 2 || usage ;;
        --top)     TOP="${2:-}";     shift 2 || usage ;;
        --tier)    TIER="${2:-}";    shift 2 || usage ;;
        --pool)    POOL="${2:-}";    shift 2 || usage ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
[ -n "$SOURCES" ] || usage
case "$TOP" in ''|*[!0-9]*) usage ;; esac
case "$TIER" in ''|code|dsl) ;; *) usage ;; esac
case "$POOL" in summary|crux) ;; *) usage ;; esac
# A crux is code, so the DSL tier has nothing to contribute to it. Set here
# rather than checked at every use, so the two selectors cannot disagree.
[ "$POOL" != "crux" ] || TIER="code"
[ -f "$SOURCES" ] || { echo "synapse-rank: no such sources file: $SOURCES" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-rank: git required" >&2; exit 1; }
if [ -n "$REPO" ]; then
    REPO_ROOT="$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || { echo "synapse-rank: not inside a git repo" >&2; exit 1; }

TAGS_SH="$HOME/.claude/bin/synapse-tags.sh"
[ -x "$TAGS_SH" ] || { echo "synapse-rank: synapse-tags.sh not installed (run setup.sh)" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/synapse-rank.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/chunks" "$W/out"

# Same list synapse-vocab.sh uses, for the same reason: these are the languages
# a grammar exists for, which is a different question from what belongs in the
# graph.
CODE_RE='\.(java|kt|kts|scala|groovy|gradle|js|jsx|ts|tsx|py|go|rs|c|cc|cpp|h|hpp|cs|rb|php|swift|sh|bash)$'

# Test files, by the conventions that actually recur across languages: a path
# segment named test/spec, a `FooTest`/`FooSpec` basename, a `_test`/`.test.`
# suffix, a `test_` prefix. The capital in `[a-z0-9](Tests?|Spec)` is the whole
# point of that branch -- without it `Latest.java` reads as a test, and silently
# dropping a real implementation file from the crux pool is exactly the kind of
# wrong answer that never announces itself.
TEST_RE="${SYNAPSE_TEST_PATH_RE:-(^|/)(test|tests|spec|specs|__tests__|testing)/|[^/]*[a-z0-9](Tests?|Spec)\.[^/.]+$|[^/]*[._-](test|spec)\.[^/.]+$|(^|/)[Tt]est_[^/]*$}"

cd "$REPO_ROOT" || exit 1
LC_ALL=C sort -u "$SOURCES" | LC_ALL=C awk 'NF' > "$W/all.txt"
LC_ALL=C grep -E "$CODE_RE" "$W/all.txt" > "$W/code.txt" || : > "$W/code.txt"
LC_ALL=C grep -vE "$CODE_RE" "$W/all.txt" > "$W/noncode.txt" || : > "$W/noncode.txt"

tests_dropped=0
if [ "$POOL" = "crux" ]; then
    LC_ALL=C grep -vE "$TEST_RE" "$W/code.txt" > "$W/code-impl.txt" || : > "$W/code-impl.txt"
    tests_dropped=$(( $(LC_ALL=C wc -l < "$W/code.txt" | tr -d ' ') \
                    - $(LC_ALL=C wc -l < "$W/code-impl.txt" | tr -d ' ') ))
    mv "$W/code-impl.txt" "$W/code.txt"
fi

# stem <TAB> module <TAB> path. The module is the first two path segments, or
# whatever prefix a shallower path has; `(repo root)` for a file with none, so
# root files only ever resolve against each other.
KEY_AWK='
BEGIN { FS = "/" }
{
  path = $0
  n = NF
  file = $n
  sub(/\.[^.]*$/, "", file)
  lim = (n - 1 < 2) ? n - 1 : 2
  if (lim < 1) mod = "(repo root)"
  else { mod = $1; for (i = 2; i <= lim; i++) mod = mod "/" $i }
  print file "\t" mod "\t" path
}'

# --- code tier: definitions per KB -----------------------------------------
code_n="$(LC_ALL=C wc -l < "$W/code.txt" | tr -d ' ')"
: > "$W/code-ranked.tsv"
if [ "$code_n" -gt 0 ]; then
    NP="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    CHUNK=$(( (code_n + NP - 1) / NP ))
    [ "$CHUNK" -ge 200 ] || CHUNK=200
    split -l "$CHUNK" "$W/code.txt" "$W/chunks/c."

    cat > "$W/worker.sh" <<'WORKER'
#!/bin/bash
# worker.sh <chunk> <out-dir> <repo-root> <tags-sh>
chunk="$1"; outdir="$2"; repo="$3"; tags_sh="$4"
cd "$repo" || exit 0
"$tags_sh" --paths "$chunk" 2>/dev/null > "$outdir/$(basename "$chunk").tags"
WORKER
    chmod +x "$W/worker.sh"
    find "$W/chunks" -type f -name 'c.*' -print0 \
        | xargs -0 -P "$NP" -I {} "$W/worker.sh" {} "$W/out" "$REPO_ROOT" "$TAGS_SH"
    cat "$W"/out/*.tags > "$W/all.tags" 2>/dev/null || : > "$W/all.tags"

    # An unindented line is a path; under it, field 4 of a tag line is the
    # def/ref marker. Every path is seeded at zero so a parsed-but-empty file
    # ranks last rather than vanishing from the tier it belongs to.
    LC_ALL=C awk -F'\t' '
      /^[^\t]/ { p = $0; if (!(p in n)) n[p] = 0; next }
      p != "" && $4 ~ /^def / { n[p]++ }
      END { for (k in n) print k "\t" n[k] }
    ' "$W/all.tags" | LC_ALL=C sort > "$W/defs.tsv"

    # ONE batched stat, never a `wc -c` per path: that shape cost 15 minutes
    # against 3 seconds for the batched form on a repo of this size, and a
    # five-file fixture can never surface the difference.
    if stat -f '%z' . >/dev/null 2>&1; then stat_args=(-f '%z %N'); else stat_args=(-c '%s %n'); fi
    tr '\n' '\0' < "$W/code.txt" \
        | xargs -0 stat "${stat_args[@]}" 2>/dev/null \
        | LC_ALL=C awk '{ size = $1; sub(/^[0-9]+ /, ""); print $0 "\t" size }' \
        | LC_ALL=C sort > "$W/sizes.tsv"

    # Definitions per kilobyte. A file whose size we could not read is dropped
    # rather than scored as infinitely dense.
    LC_ALL=C awk -F'\t' '
      NR == FNR { size[$1] = $2 + 0; next }
      ($1 in size) && size[$1] > 0 { printf "code\t%.3f\t%s\n", ($2 * 1000.0) / size[$1], $1 }
    ' "$W/sizes.tsv" "$W/defs.tsv" \
        | LC_ALL=C sort -t"$(printf '\t')" -k2,2gr -k3,3 > "$W/code-ranked.tsv"
fi

# --- dsl tier: hop from a declaration to the code that consumes it ----------
: > "$W/dsl-ranked.tsv"
if [ -s "$W/noncode.txt" ]; then
    git ls-files 2>/dev/null | LC_ALL=C grep -E "$CODE_RE" > "$W/repo-code.txt" || : > "$W/repo-code.txt"
    LC_ALL=C awk "$KEY_AWK" "$W/repo-code.txt" > "$W/code-keys.tsv"
    LC_ALL=C awk "$KEY_AWK" "$W/noncode.txt"   > "$W/dsl-keys.tsv"

    # Bucketed by module first, so the prefix comparison only ever runs against
    # candidates that could match. Unbucketed this is every declaration against
    # every code file in the repo -- 98k of them on a large one.
    LC_ALL=C awk -F'\t' '
      NR == FNR { m = $2; i = ++cnt[m]; stem[m, i] = $1; path[m, i] = $3; next }
      # A stem under three characters prefixes half the repo and tells you
      # nothing, so it is not a hop worth making.
      length($1) < 3 { next }
      {
        m = $2; s = $1
        for (i = 1; i <= cnt[m]; i++)
          if (index(stem[m, i], s) == 1) served[path[m, i]]++
      }
      END { for (p in served) printf "dsl\t%d\t%s\n", served[p], p }
    ' "$W/code-keys.tsv" "$W/dsl-keys.tsv" \
        | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k3,3 > "$W/dsl-ranked.tsv"
fi

emit() { # emit <file>
    if [ "$TOP" -eq 0 ]; then cat "$1"; else head -n "$TOP" "$1"; fi
}
[ "$TIER" = "dsl" ] || emit "$W/code-ranked.tsv"
[ "$TIER" = "code" ] || emit "$W/dsl-ranked.tsv"

# Tests dropped is reported rather than merely done: a crux pool that silently
# shrank would look identical to a node that simply has few code files.
printf 'synapse-rank: pool %s, %s sources -> code %s, dsl-consumers %s, unranked %s, tests-excluded %s\n' \
    "$POOL" \
    "$(LC_ALL=C wc -l < "$W/all.txt" | tr -d ' ')" \
    "$(LC_ALL=C wc -l < "$W/code-ranked.tsv" | tr -d ' ')" \
    "$(LC_ALL=C wc -l < "$W/dsl-ranked.tsv" | tr -d ' ')" \
    "$(LC_ALL=C wc -l < "$W/noncode.txt" | tr -d ' ')" \
    "$tests_dropped" >&2
exit 0
