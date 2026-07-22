#!/bin/bash
# Registers the Obsidian Local REST API + MCP plugin with Claude Code:
# extracts the plugin's self-generated cert + API key from its data.json
# (only exists after you've installed + enabled the plugin via the
# Obsidian UI), writes a standalone CA cert file, wires NODE_EXTRA_CA_CERTS
# into ~/.claude/settings.json (user scope, merged not overwritten), and
# registers the `obsidian` MCP server at user scope (works from any
# project). Safe to re-run.
set -euo pipefail

VAULT="${1:-}"
if [ -z "$VAULT" ]; then
  echo "Usage: $0 <path-to-obsidian-vault>" >&2
  exit 1
fi

PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
if [ ! -f "$PLUGIN_DATA" ]; then
  echo "Plugin data not found at: $PLUGIN_DATA" >&2
  echo "Install + enable 'Local REST API with MCP' in Obsidian first." >&2
  exit 1
fi

command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
command -v claude >/dev/null || { echo "claude CLI is required." >&2; exit 1; }

CERT_PATH="$HOME/.claude/obsidian-local-rest-api-ca.pem"
API_KEY="$(jq -r '.apiKey' "$PLUGIN_DATA")"
PORT="$(jq -r '.port' "$PLUGIN_DATA")"

jq -r '.crypto.cert' "$PLUGIN_DATA" > "$CERT_PATH"
echo "Wrote CA cert to $CERT_PATH"

# Verify it actually validates before wiring anything in
if ! curl -s --cacert "$CERT_PATH" "https://127.0.0.1:$PORT/" -o /dev/null --max-time 5; then
  echo "WARNING: cert didn't validate against https://127.0.0.1:$PORT/ -- is Obsidian running?" >&2
fi

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
TMP="$(mktemp)"
jq --arg cert "$CERT_PATH" '.env = (.env // {}) | .env.NODE_EXTRA_CA_CERTS = $cert' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
echo "Wired NODE_EXTRA_CA_CERTS into ~/.claude/settings.json"

claude mcp remove obsidian -s user >/dev/null 2>&1 || true
claude mcp add --transport http obsidian "https://127.0.0.1:$PORT/mcp/" \
  --header "Authorization: Bearer $API_KEY" \
  -s user
echo "Registered 'obsidian' MCP server at user scope."
echo ""
echo "Restart Claude Code for this session to pick up the new tools."
