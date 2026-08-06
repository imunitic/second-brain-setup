#!/bin/bash
# UserPromptSubmit hook: inject matching Synapse nodes into context on every
# turn, not just once at session start -- see docs/synapse-graph.md's "What
# every prompt is told" section for the full mechanism and why. Set
# SYNAPSE_DISABLE_PROMPT_INJECTION (any value) to disable entirely.
#
# Every exit path before the final output is a genuine zero/near-zero-cost
# no-op: disabled, no prompt text, not a git repo, no Synapse namespace for
# this repo, or nothing distinctive extracted from the prompt all skip the
# network call entirely -- the one real cost (a single POST to the vault's
# search endpoint) is paid only when there's an actual candidate query to run.
set -uo pipefail

[ -n "${SYNAPSE_DISABLE_PROMPT_INJECTION:-}" ] && exit 0

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

# Field name not yet verified against a real captured UserPromptSubmit
# payload -- `prompt` matches Claude Code's documented convention for this
# hook event, same way `session_id` (verified, see synapse-stop-nudge.sh) and
# `tool_input`/`tool_response` (verified, see synapse-staleness.sh) are named
# for their events. Confirm this the first time the hook actually fires for
# real; an empty PROMPT below fails soft (exits before any network call), so
# a wrong field name degrades to "hook never does anything," not a crash.
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty')"
[ -n "$PROMPT" ] || exit 0

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[ -n "$CWD" ] || CWD="$PWD"

REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || exit 0

# One shared resolution of repo, branch and remote, so this hook cannot drift
# from synapse-staleness.sh / synapse-session-start.sh / synapse-query.sh.
# shellcheck source=/dev/null
. "$HOME/.claude/bin/synapse-identity.sh" 2>/dev/null || exit 0
REMOTE="$(synapse_remote "$REPO_ROOT")"
# Detached HEAD: no branch, so no namespace to inject context from.
REPO_NAME="$(synapse_namespace "$REPO_ROOT" 2>/dev/null)" || exit 0

NS_INDEX="$VAULT/synapse/$REPO_NAME/Index.md"
[ -f "$NS_INDEX" ] || exit 0
NS_REMOTE="$(grep -m1 '^remote:' "$NS_INDEX" 2>/dev/null \
  | sed -e 's/^remote: *//' -e 's/^"//' -e 's/"$//' || true)"
[ -n "$NS_REMOTE" ] && [ "$NS_REMOTE" = "$REMOTE" ] || exit 0

TOKENIZER="$HOME/.claude/bin/synapse-tokenizer.sh"
[ -x "$TOKENIZER" ] || exit 0
TERMS="$("$TOKENIZER" "$PROMPT")"
[ -n "$TERMS" ] || exit 0

REGEXP="$(printf '%s' "$TERMS" | paste -sd'|' -)"

QUERY="$(jq -nc --arg glob "synapse/$REPO_NAME/*" --arg re "$REGEXP" '
  {"and": [{"glob": [$glob, {"var": "path"}]}, {"regexp": [$re, {"var": "content"}]}]}
')"

RESULTS="$(curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/vnd.olrapi.jsonlogic+json' \
  -X POST --data-binary "$QUERY" "$BASE/search/" 2>/dev/null || true)"
[ -n "$RESULTS" ] || exit 0

PATHS="$(printf '%s' "$RESULTS" | jq -r '.[]?.filename // empty' 2>/dev/null || true)"
[ -n "$PATHS" ] || exit 0

LIST="$(printf '%s\n' "$PATHS" | sed 's/^/  - /')"

jq -n --arg ctx "Synapse nodes matching this prompt:
$LIST

Consult the relevant one(s) with synapse-query.sh body before grepping, per the synapse-query skill." '
  {
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $ctx
    }
  }'
