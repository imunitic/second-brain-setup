#!/bin/bash
# Builds and uploads synapse/{repo}/_index.json -- the machine-only reverse index
# from every source path to the node filenames that claim it, plus _unassigned.
# Step 3 of a scripted /synapse-init.
#
# Usage: synapse-build-index.sh
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo-name}/.
#
# Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title, unassigned.txt
# Writes synapse/{repo}/_index.json in the vault
#
# Read by the PostToolUse staleness hook, so it must cover every enumerated file:
# an edit to an unlisted path flags nothing stale. Tens of megabytes on a large
# repo, hence jq rather than authoring it.
#
# Note for agent callers: needs the sandbox disabled (localhost REST API).
set -euo pipefail

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
readonly CONF
readonly CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

command -v jq >/dev/null || { echo "synapse-build-index: jq required" >&2; exit 1; }
command -v git >/dev/null || { echo "synapse-build-index: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-build-index: not inside a git repo" >&2; exit 1; }
REPO_NAME="$(basename "$REPO_ROOT")"

# Never $PWD: that is the repo, and working files do not belong in a user's checkout.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
readonly LISTS="$WORK_DIR/lists"

[[ -d "$LISTS" ]] || { echo "synapse-build-index: no lists/ in $WORK_DIR" >&2; exit 1; }
[[ -f "$WORK_DIR/unassigned.txt" ]] || { echo "synapse-build-index: no unassigned.txt in $WORK_DIR" >&2; exit 1; }

# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[[ -n "$VAULT" && -d "$VAULT" ]] || { echo "synapse-build-index: no vault" >&2; exit 1; }
readonly PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
[[ -f "$PLUGIN_DATA" && -f "$CERT" ]] || { echo "synapse-build-index: REST API not configured" >&2; exit 1; }
API_KEY="$(jq -r '.apiKey // empty' "$PLUGIN_DATA")"
PORT="$(jq -r '.port // empty' "$PLUGIN_DATA")"
[[ -n "$API_KEY" && -n "$PORT" ]] || { echo "synapse-build-index: no API key/port" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/synapse-index.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# path<TAB>node.md for every (list, path) pair. The `.md` extension is part of
# the value: the staleness hook and the read-time procedure both use it directly
# as a vault path with no extension handling of their own.
for list in "$LISTS"/*.txt; do
    nn="$(basename "$list" .txt)"
    [[ -f "$LISTS/$nn.title" ]] || continue
    node="$(tr '/:*?"<>|' '_' < "$LISTS/$nn.title").md"
    awk -v n="$node" 'NF { printf "%s\t%s\n", $0, n }' "$list"
done > "$work/pairs.tsv"

[[ -s "$work/pairs.tsv" ]] || { echo "synapse-build-index: no (path, node) pairs" >&2; exit 1; }

jq -Rn --rawfile unassigned "$WORK_DIR/unassigned.txt" '
  [inputs | split("\t") | {path: .[0], node: .[1]}]
  | group_by(.path)
  | map({key: .[0].path, value: [.[].node] | sort})
  | from_entries
  | . + {"_unassigned": ($unassigned | split("\n") | map(select(length > 0)))}
' < "$work/pairs.tsv" > "$work/_index.json"

jq -e . "$work/_index.json" > /dev/null

http_code="$(curl -s -o "$work/resp" -w '%{http_code}' -X PUT \
    --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "@$work/_index.json" \
    "https://127.0.0.1:$PORT/vault/synapse/$REPO_NAME/_index.json")"

case "$http_code" in
    20*) printf '_index.json written: keys=%s unassigned=%s bytes=%s\n' \
            "$(jq 'keys | length' "$work/_index.json")" \
            "$(jq '._unassigned | length' "$work/_index.json")" \
            "$(wc -c < "$work/_index.json" | tr -d ' ')" ;;
    *) echo "synapse-build-index: PUT failed ($http_code): $(cat "$work/resp")" >&2; exit 1 ;;
esac
