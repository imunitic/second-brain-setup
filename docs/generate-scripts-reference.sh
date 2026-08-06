#!/bin/bash
# Generates docs/scripts.md from the header block of every claude/bin/*.sh.
#
# Usage: docs/generate-scripts-reference.sh [--check]
#
#   --check  exit 1 if docs/scripts.md is out of date, without writing it.
#            Wired into the test suite, so a stale reference fails visibly
#            instead of quietly describing a script that has moved on.
#
# The header block is the same text each script prints for --help, so there is one
# source of truth rather than a doc that has to be remembered. Extraction stops at
# the first non-comment line: the block runs from the `# Usage` line to `set -e`.
#
# THE MARKER IS `^# Usage`, NOT `^# Usage:`, and the difference already cost a
# broken page. A header cannot find the marker produces TWO defects at once, both
# of which render as perfectly plausible markdown: the prose pass never stops, so
# the usage lines are absorbed into the paragraph, and the help pass never starts,
# so the fence comes out empty. `synapse-identity.sh` says
# `# Usage (sourced, never executed):` -- it is sourced rather than run, so the
# parenthetical is real information -- and against a `^# Usage:` marker it
# rendered exactly that way. A missing marker is now a hard error rather than a
# quietly malformed section; see `validate` below.
#
# Exit codes: 0 ok (or up to date), 1 out of date with --check or a header the
# marker cannot find, 2 usage error
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BIN="$HERE/../claude/bin"
readonly OUT="$HERE/scripts.md"

# Defined once and shared by both extraction passes. They must agree: when they
# disagree the output is malformed rather than absent, which is why this is a
# variable and not the same regex typed twice.
readonly USAGE_RE='^# Usage'

check_only=false
case "${1:-}" in
    "") ;;
    --check) check_only=true ;;
    *) awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2; exit 2 ;;
esac

# Every script must yield a non-empty help block. Checked before anything is
# written, and named per script, because the failure this guards is silent: an
# empty fence and a swallowed paragraph both look like ordinary output.
validate() {
    local f name n bad=0
    for f in "$BIN"/*.sh; do
        name="$(basename "$f")"
        n="$(awk -v re="$USAGE_RE" '$0 ~ re { p = 1 } p && !/^#/ { exit } p { print }' "$f" | wc -l | tr -d ' ')"
        if [[ "$n" -eq 0 ]]; then
            echo "generate-scripts-reference: $name has no '# Usage' line in its header block" >&2
            bad=1
        fi
    done
    return "$bad"
}

# The one-line purpose is the comment above the `# Usage` line; the rest is help text.
render() {
    cat <<'EOF'
# Synapse Tools: script reference

Generated from the header block of each script by `docs/generate-scripts-reference.sh`
— the same text the script prints for `--help`. Do not edit by hand; run the
generator, or `--check` it, which the test suite does.

Design rationale is not here: see [synapse-graph.md](synapse-graph.md) for the Graph these
scripts build and why they exist at all, and [synapse-vault.md](synapse-vault.md) for
the Vault that hosts it.

EOF
    local f name
    for f in "$BIN"/*.sh; do
        name="$(basename "$f")"
        printf '## `%s`\n\n' "$name"
        awk -v re="$USAGE_RE" '$0 ~ re { exit } !/^#/ { exit } NR > 1 && !/^#$/ { sub(/^# ?/, ""); print }' "$f"
        printf '\n```\n'
        awk -v re="$USAGE_RE" '$0 ~ re { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$f"
        printf '```\n\n'
    done
}

validate || exit 1

if [[ "$check_only" == true ]]; then
    if [[ ! -f "$OUT" ]]; then
        echo "generate-scripts-reference: $OUT does not exist -- run without --check" >&2
        exit 1
    fi
    if ! diff -q <(render) "$OUT" >/dev/null; then
        echo "generate-scripts-reference: docs/scripts.md is out of date" >&2
        diff <(render) "$OUT" | head -20 >&2
        exit 1
    fi
    echo "docs/scripts.md is up to date"
    exit 0
fi

render > "$OUT"
printf 'wrote %s (%s scripts, %s lines)\n' \
    "${OUT#"$HERE/../"}" "$(find "$BIN" -name '*.sh' | wc -l | tr -d ' ')" \
    "$(wc -l < "$OUT" | tr -d ' ')"
