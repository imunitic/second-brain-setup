#!/bin/bash
# Writes every node that has both a path list and an authored body. Step 2 of a
# scripted /synapse-init.
#
# Usage: synapse-push-nodes.sh [NN ...]      (default: every staged or authored node)
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#
# Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (from synapse-build-lists.sh)
#        $SYNAPSE_WORK_DIR/b-NN.md                   (authored per node, see below)
# Calls  synapse-write-node.sh once per node.
#
# Each b-NN.md carries its own one-line summary in frontmatter, so everything
# authored about a node lives in one file:
#
#     ---
#     summary: One line differentiating this node from its siblings.
#     ---
#
#     ## Summary
#     ...
#
# The frontmatter is stripped before the rest is passed on as the node body, and the
# summary becomes the node's `summary` field. A node without one is an error rather
# than a default, because the index bullet has nothing to say without it.
#
# Note for agent callers: needs the sandbox disabled (localhost REST API).
set -euo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

command -v git >/dev/null || { echo "synapse-push-nodes: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-push-nodes: not inside a git repo" >&2; exit 1; }

# Never $PWD: that is the repo, and working files do not belong in a user's checkout.
# Keyed by the same "{repo}@{branch}" its siblings use -- build-lists.sh writes
# this directory and push-nodes.sh reads it, so a different key here would have
# them silently disagree about where a build's path lists live. Per-branch is
# also what the contents want: `all.txt` is reused unless --reenumerate is
# passed, and reusing another branch's enumeration is exactly the drift that
# rule exists to avoid.
# shellcheck source=/dev/null
. "$HOME/.claude/bin/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-push-nodes: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
readonly LISTS="$WORK_DIR/lists"
# Resolve the writer next to this script, so an installed copy finds its sibling
# rather than whatever happens to be on PATH.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WRITER="$SCRIPT_DIR/synapse-write-node.sh"

[[ -x "$WRITER" ]] || { echo "synapse-push-nodes: missing $WRITER" >&2; exit 1; }
[[ -d "$LISTS" ]] || { echo "synapse-push-nodes: no lists/ in $WORK_DIR -- run synapse-build-lists.sh first" >&2; exit 1; }

# bash 3.2 on macOS has no mapfile, hence the plain string. The default target set
# is the union of staged lists and authored bodies, so an un-authored node reports
# as a SKIP rather than vanishing.
if [[ $# -gt 0 ]]; then
    targets="$*"
else
    # `find`, not `ls`: a no-match glob makes ls exit non-zero, which under
    # `set -e` + `pipefail` kills the script inside this substitution -- silently,
    # since ls's stderr is suppressed.
    targets="$( {
        find "$LISTS" -maxdepth 1 -name '[0-9][0-9].title' | sed -E 's#.*/([0-9]{2})\.title$#\1#'
        find "$WORK_DIR" -maxdepth 1 -name 'b-[0-9][0-9].md' | sed -E 's#.*/b-([0-9]{2})\.md$#\1#'
    } | LC_ALL=C sort -u | tr '\n' ' ')"
fi
[[ -n "${targets// /}" ]] || {
    echo "synapse-push-nodes: nothing to push (no lists/NN.title or b-NN.md in $WORK_DIR)" >&2
    exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/synapse-push.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pushed=0
failed=0
for nn in $targets; do
    body="$WORK_DIR/b-$nn.md"
    list="$LISTS/$nn.txt"
    title_file="$LISTS/$nn.title"
    if [[ ! -f "$body" ]]; then
        printf '%s\tSKIP (no body)\n' "$nn"
        continue
    fi
    if [[ ! -s "$list" || ! -f "$title_file" ]]; then
        printf '%s\tSKIP (no list/title)\n' "$nn"
        continue
    fi
    summary="$(awk '
        NR == 1 && $0 == "---" { fm = 1; next }
        fm && $0 == "---" { exit }
        fm && index($0, "summary:") == 1 {
            sub(/^summary:[[:space:]]*/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }' "$body")"
    if [[ -z "$summary" ]]; then
        printf '%s\tFAILED (no `summary:` frontmatter in b-%s.md)\n' "$nn" "$nn"
        failed=$((failed + 1))
        continue
    fi

    # Pass on only what follows the frontmatter, so the summary is not repeated
    # inside the node's prose.
    stripped="$work/b-$nn.md"
    awk '
        NR == 1 && $0 == "---" { fm = 1; next }
        fm && $0 == "---" { fm = 0; body = 1; next }
        body' "$body" > "$stripped"

    if result="$("$WRITER" --title "$(cat "$title_file")" --summary "$summary" --paths "$list" --body "$stripped")"; then
        printf '%s\t%s\n' "$nn" "$result"
        pushed=$((pushed + 1))
    else
        printf '%s\tFAILED\n' "$nn"
        failed=$((failed + 1))
    fi
done

[[ "$failed" -eq 0 ]] || { echo "synapse-push-nodes: $failed node(s) failed" >&2; exit 1; }
# All-skipped is a failure too: the caller asked for a push and got none, which
# otherwise reads as success.
[[ "$pushed" -gt 0 ]] || { echo "synapse-push-nodes: nothing to push (no node had both a list and a body)" >&2; exit 1; }
