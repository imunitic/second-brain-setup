#!/bin/bash
# Prints `tree-sitter tags` output (definitions + name-based call references)
# for a single file, cloning/registering that language's grammar on first use.
# Deliberately dumb/mechanical -- no reasoning here. See docs/synapse-graph.md's
# "Optional tree-sitter acceleration" section and `synapse-grammars.conf`'s own
# header for the design.
#
# Usage: synapse-tags.sh <file-path>
#   Grammar cache dir: $SYNAPSE_GRAMMARS_DIR, default ~/.cache/synapse/grammars/.
#
# Exit codes (every caller must fail soft on any non-zero and fall back to
# reading the file directly -- this is never a hard dependency):
#   0 - tags printed to stdout
#   1 - not usable right now (missing tree-sitter/jq/C compiler, no
#       extension, a registry entry marked `unsupported: true`, or a clone/
#       registration failure) -- nothing else to try
#   2 - extension has no registry entry at all -- the caller (a Claude
#       procedure, e.g. /synapse-init) should run grammar discovery and
#       retry, not treat this the same as a hard failure
set -uo pipefail

FILE="${1:-}"
[ -n "$FILE" ] && [ -f "$FILE" ] || exit 1

command -v tree-sitter >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || exit 1

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
GRAMMARS_DIR="${SYNAPSE_GRAMMARS_DIR:-$HOME/.cache/synapse/grammars}"
REGISTRY="$HOME/.claude/synapse-grammars.conf"

BASENAME="$(basename "$FILE")"
EXT="${BASENAME##*.}"
[ "$EXT" != "$BASENAME" ] || exit 1
EXT="$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')"

[ -f "$REGISTRY" ] || printf '{}' > "$REGISTRY"

ENTRY="$(jq -r --arg ext "$EXT" '.[$ext] // empty' "$REGISTRY" 2>/dev/null)"
[ -n "$ENTRY" ] || exit 2

UNSUPPORTED="$(printf '%s' "$ENTRY" | jq -r '.unsupported // false' 2>/dev/null)"
[ "$UNSUPPORTED" != "true" ] || exit 1

REPO="$(printf '%s' "$ENTRY" | jq -r '.repo // empty' 2>/dev/null)"
SCOPE="$(printf '%s' "$ENTRY" | jq -r '.scope // empty' 2>/dev/null)"
[ -n "$REPO" ] && [ -n "$SCOPE" ] || exit 1

REPO_NAME="$(basename "$REPO" .git)"
REPO_DIR="$GRAMMARS_DIR/repos/$REPO_NAME"
mkdir -p "$GRAMMARS_DIR/repos"

if [ ! -d "$REPO_DIR" ]; then
  git clone --depth 1 -q "$REPO" "$REPO_DIR" >/dev/null 2>&1 || { rm -rf "$REPO_DIR"; exit 1; }
fi

TS_CONFIG="$HOME/.config/tree-sitter/config.json"
[ -f "$TS_CONFIG" ] || tree-sitter init-config >/dev/null 2>&1
[ -f "$TS_CONFIG" ] || exit 1

# tree-sitter scans each parser-directories entry for grammar repos living
# *inside* it -- registering the repo dir itself (rather than its parent)
# leaves --scope resolution failing with "Unknown scope", confirmed by
# testing directly against a real grammar.
REPOS_PARENT="$GRAMMARS_DIR/repos"
ALREADY_REGISTERED="$(jq -r --arg d "$REPOS_PARENT" '(."parser-directories" // []) | index($d) != null' "$TS_CONFIG" 2>/dev/null)"
if [ "$ALREADY_REGISTERED" != "true" ]; then
  # Explicit template: macOS `mktemp` with no template ignores TMPDIR.
  TMP="$(mktemp "${TMPDIR:-/tmp}/synapse-tags.XXXXXX")"
  jq --arg d "$REPOS_PARENT" '."parser-directories" = ((."parser-directories" // []) + [$d] | unique)' "$TS_CONFIG" > "$TMP" 2>/dev/null && mv "$TMP" "$TS_CONFIG"
fi

tree-sitter tags --scope "$SCOPE" "$FILE" 2>/dev/null
