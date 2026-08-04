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
# the first non-comment line: the block runs from `# Usage:` to `set -e`.
#
# Exit codes: 0 ok (or up to date), 1 out of date with --check, 2 usage error
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BIN="$HERE/../claude/bin"
readonly OUT="$HERE/scripts.md"

check_only=false
case "${1:-}" in
    "") ;;
    --check) check_only=true ;;
    *) awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2; exit 2 ;;
esac

# The one-line purpose is the comment above `# Usage:`; the rest is the help text.
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
        awk '/^# Usage:/ { exit } !/^#/ { exit } NR > 1 && !/^#$/ { sub(/^# ?/, ""); print }' "$f"
        printf '\n```\n'
        awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$f"
        printf '```\n\n'
    done
}

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
