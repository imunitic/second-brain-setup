#!/bin/bash
# Builds and uploads synapse/{repo}/Index.md -- the per-project node map, carrying
# the `remote` field the SessionStart hook verifies before injecting a pointer.
# Step 4 (last) of a scripted /synapse-init.
#
# Usage: synapse-build-project-index.sh
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#
# Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (for titles and file counts)
#        each node's `summary` frontmatter field, fetched from the vault
#
# Run after the nodes exist: summaries are read back off the nodes, and a node that
# is missing or has no `summary` is a hard error. Emits no repo-specific prose of
# its own -- see docs/synapse-graph.md for why.
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

command -v git >/dev/null || { echo "synapse-build-project-index: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || {
    echo "synapse-build-project-index: not inside a git repo" >&2; exit 1; }

# "{repo}@{branch}", not a bare repo name -- see synapse-identity.sh.
# shellcheck source=/dev/null
. "$HOME/.claude/bin/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-build-project-index: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

# Never $PWD: that is the repo, and working files do not belong in a user's checkout.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
readonly LISTS="$WORK_DIR/lists"
# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
readonly CONF
readonly CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"

[[ -d "$LISTS" ]] || { echo "synapse-build-project-index: no lists/ in $WORK_DIR" >&2; exit 1; }
command -v jq >/dev/null || { echo "synapse-build-project-index: jq required" >&2; exit 1; }

# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[[ -n "$VAULT" && -d "$VAULT" ]] || { echo "synapse-build-project-index: no vault" >&2; exit 1; }
readonly PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
[[ -f "$PLUGIN_DATA" && -f "$CERT" ]] || {
    echo "synapse-build-project-index: REST API not configured" >&2; exit 1; }
API_KEY="$(jq -r '.apiKey // empty' "$PLUGIN_DATA")"
PORT="$(jq -r '.port // empty' "$PLUGIN_DATA")"
[[ -n "$API_KEY" && -n "$PORT" ]] || { echo "synapse-build-project-index: no API key/port" >&2; exit 1; }

# Same origin -> first-remote -> repo-root resolution as every other Synapse
# component. A mismatch here is what makes the SessionStart hook stay silent.
REMOTE="$(synapse_remote "$REPO_ROOT")"

work="$(mktemp -d "${TMPDIR:-/tmp}/synapse-pindex.XXXXXX")"
trap 'rm -rf "$work"' EXIT


# Every node's `summary` in one request, rather than one fetch per node. The field
# is frontmatter, and the API can evaluate a frontmatter expression across the vault
# and return just the value -- which is what its search endpoint is for. Fetching
# whole notes to read one line each moved ~34 MB for 48 nodes on a large repository,
# because a hub node's `sources` block is megabytes; this is a few kilobytes.
#
# The value arrives already parsed, so the YAML unescaping the old per-node reader
# had to do (backslashes before quotes, on a sentinel to avoid mangling \\") is
# gone with it.
if ! curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
        -H 'Content-Type: application/vnd.olrapi.jsonlogic+json' \
        -X POST --data-binary '{"var": "frontmatter.summary"}' \
        -o "$work/summaries.json" "https://127.0.0.1:$PORT/search/"; then
    echo "synapse-build-project-index: the vault search request failed" >&2
    exit 1
fi
# Interpolated rather than @tsv: @tsv escapes backslashes, so a summary mentioning
# a path like C:\dir would arrive with the backslash doubled and nothing would undo
# it. Tabs are squashed to spaces because they are the field separator here; a
# summary is a single-line scalar, so newlines cannot occur.
jq -r --arg pfx "synapse/$REPO_NAME/" '
    .[]? | select(.filename | startswith($pfx))
    | (.filename | ltrimstr($pfx) | rtrimstr(".md")) as $n
    | (.result | tostring | gsub("\t"; " ")) as $v
    | "\($n)\t\($v)"
' "$work/summaries.json" > "$work/summaries.tsv" || {
    echo "synapse-build-project-index: could not read the search response" >&2
    exit 1
}

# One `title<TAB>count<TAB>summary` line per node, sorted by title -- alphabetical
# because an index of several dozen entries is something a reader scans for a name,
# and any other order would need a rule nobody could guess.
: > "$work/bullets.tsv"
while IFS= read -r title_file; do
    nn="$(basename "$title_file" .title)"
    title="$(cat "$title_file")"
    link="$(printf '%s' "$title" | tr '/:*?"<>|' '_')"
    count="$(wc -l < "$LISTS/$nn.txt" | tr -d ' ')"

    summary="$(awk -F'\t' -v n="$link" '$1 == n { print $2; exit }' "$work/summaries.tsv")"
    if [[ -z "$summary" ]]; then
        # The search returns only notes whose summary is set, so an absent row means
        # either no node or no summary. A stat separates them, because the two need
        # different fixes and the old code distinguished them.
        if [[ ! -f "$VAULT/synapse/$REPO_NAME/$link.md" ]]; then
            echo "synapse-build-project-index: node not in the vault: $link.md" >&2
            echo "  the index is built from the nodes, so write them first" >&2
        else
            echo "synapse-build-project-index: no summary field on $link.md" >&2
        fi
        exit 1
    fi
    printf '%s\t%s\t%s\n' "$link" "$count" "$summary" >> "$work/bullets.tsv"
done < <(find "$LISTS" -name '*.title' | LC_ALL=C sort)

LC_ALL=C sort -t"$(printf '\t')" -k1,1 "$work/bullets.tsv" -o "$work/bullets.tsv"

node_count="$(find "$LISTS" -name '*.txt' | wc -l | tr -d ' ')"
if [[ -s "$WORK_DIR/all.txt" ]]; then
    total_files="$(wc -l < "$WORK_DIR/all.txt" | tr -d ' ')"
else
    total_files="$(cat "$LISTS"/*.txt | LC_ALL=C sort -u | wc -l | tr -d ' ')"
fi
built_at="$(date '+%Y-%m-%d %H:%M')"

{
    echo '---'
    printf 'title: "%s — Synapse index"\n' "$REPO_NAME"
    echo 'node_type: synapse-index'
    printf 'project: %s\n' "$REPO_NAME"
    printf 'remote: "%s"\n' "$REMOTE"
    printf 'built_at: "%s"\n' "$built_at"
    echo '---'
    echo
    printf '# %s — Synapse index\n' "$REPO_NAME"
    echo
    printf '%s tracked files, %s nodes. Nodes are subsystems and concepts, not modules — each one'"'"'s frontmatter `sources` lists every file it covers, and `_index.json` is the reverse index from any path back to its owning node.\n' \
        "$total_files" "$node_count"
    echo
    echo 'Reading a node: use `synapse-query.sh body <node>` rather than opening the file — `sources` runs to tens of thousands of tokens on the hub nodes and `_index.json` is far larger still. `synapse-query.sh sources <node> --modules` gives the module breakdown, `--count` just the number, and `synapse-query.sh stale` verifies the whole namespace against the working tree.'
    echo
    # Link by filename, since that is what Obsidian resolves -- a title needing
    # sanitizing would otherwise produce a link to nothing.
    while IFS=$'\t' read -r link count summary; do
        [[ -n "$link" ]] || continue
        printf -- '- [[%s]] — %s (%s files)\n' "$link" "$summary" "$count"
    done < "$work/bullets.tsv"
} > "$work/Index.md"

http_code="$(curl -s -o "$work/resp" -w '%{http_code}' -X PUT \
    --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: text/markdown" \
    --data-binary "@$work/Index.md" \
    "https://127.0.0.1:$PORT/vault/synapse/$REPO_NAME/Index.md")"

case "$http_code" in
    20*) printf 'Index.md written: %s nodes, %s tracked files, remote=%s\n' \
            "$node_count" "$total_files" "$REMOTE" ;;
    *) echo "synapse-build-project-index: PUT failed ($http_code): $(cat "$work/resp")" >&2; exit 1 ;;
esac
