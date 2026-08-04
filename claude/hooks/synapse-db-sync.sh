#!/bin/bash
# PostToolUse hook (Write|Edit|mcp__obsidian__vault_(write|patch|append|delete|move)):
# commit any agent-driven vault change to the vault's local git repo (if
# one exists -- this is opt-in per-vault, not assumed). Matches on the MCP
# vault mutation tools too, not just the native Write/Edit tools, since
# /synapse-note and the synapse-task skill write through mcp__obsidian__vault_*
# rather than editing files directly.
# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT/.git" ] || exit 0
cd "$VAULT" || exit 0
git add -A
git diff --cached --quiet && exit 0
git commit --quiet -m "auto: vault edit via Claude Code" || true
