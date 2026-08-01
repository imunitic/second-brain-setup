#!/usr/bin/env bats
# Tests setup.sh: installs the portable tooling into $HOME/.claude and
# merges hook wiring into settings.json. Runs entirely against a scratch
# $HOME -- never touches the real ~/.claude.

load 'test_helper'

SETUP_SH="$REPO_ROOT/setup.sh"

setup() {
  common_setup
  # setup.sh writes its own second-brain.conf if missing; common_setup
  # already wrote one, which is exactly the "already exists" case most of
  # these tests want. A couple of tests below remove it to test first-run
  # behavior instead.
}

teardown() {
  common_teardown
}

hook_count() {
  # Count PostToolUse/SessionStart/Stop hook entries in settings.json whose
  # command matches the given substring.
  jq --arg cmd "$1" '[.hooks[]?[]?.hooks[]? | select(.command == $cmd)] | length' \
    "$HOME/.claude/settings.json"
}

@test "first run installs hooks, commands, and skills, all hooks executable" {
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.claude/hooks/synapse-staleness.sh" ]
  [ -x "$HOME/.claude/hooks/synapse-staleness.sh" ]
  [ -f "$HOME/.claude/hooks/second-brain-session-start.sh" ]
  [ -x "$HOME/.claude/hooks/second-brain-session-start.sh" ]

  [ -f "$HOME/.claude/commands/synapse-init.md" ]
  [ -f "$HOME/.claude/commands/sb-note.md" ]
  [ -f "$HOME/.claude/commands/sb-design-note.md" ]
  [ -f "$HOME/.claude/commands/sb-task-note.md" ]
  [ -f "$HOME/.claude/skills/synapse-node/SKILL.md" ]
  [ -f "$HOME/.claude/skills/sb-task/SKILL.md" ]

  [ -f "$HOME/.claude/CLAUDE.md" ]
}

@test "first run: no org-roam-era files installed (bin/, org-task, roam-note)" {
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  [ ! -e "$HOME/.claude/bin/second-brain-switch" ]
  [ ! -e "$HOME/.claude/skills/org-task" ]
  [ ! -e "$HOME/.claude/commands/roam-note.md" ]
}

@test "re-running warns about stale pre-rename files without touching them" {
  mkdir -p "$HOME/.claude/skills/obsidian-task"
  echo "stale" > "$HOME/.claude/skills/obsidian-task/SKILL.md"

  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale files from before the sb- rename"* ]]
  # Left in place, not deleted -- setup.sh only warns, never removes.
  [ -f "$HOME/.claude/skills/obsidian-task/SKILL.md" ]
}

@test "first run wires all four hooks into settings.json exactly once" {
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  [ "$(hook_count "bash ~/.claude/hooks/second-brain-session-start.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/second-brain-db-sync.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-staleness.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/second-brain-stop-nudge.sh")" = "1" ]
}

@test "synapse-staleness.sh is wired with a Write|Edit|MultiEdit matcher" {
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  matcher="$(jq -r '.hooks.PostToolUse[] | select(.hooks[].command == "bash ~/.claude/hooks/synapse-staleness.sh") | .matcher' "$HOME/.claude/settings.json")"
  [ "$matcher" = "Write|Edit|MultiEdit" ]
}

@test "re-running is idempotent: hook counts stay at 1 after a second run" {
  bash "$SETUP_SH" >/dev/null
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  [ "$(hook_count "bash ~/.claude/hooks/second-brain-session-start.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/second-brain-db-sync.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-staleness.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/second-brain-stop-nudge.sh")" = "1" ]
}

@test "re-running preserves unrelated existing settings.json content" {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"env": {"SOME_UNRELATED_VAR": "keep-me"}}
EOF
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  val="$(jq -r '.env.SOME_UNRELATED_VAR' "$HOME/.claude/settings.json")"
  [ "$val" = "keep-me" ]
}

@test "second-brain.conf: left untouched if it already exists" {
  cat > "$HOME/.claude/second-brain.conf" <<'EOF'
OBSIDIAN_VAULT_DIR="/some/custom/path"
CUSTOM_MARKER=do-not-clobber
EOF
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  grep -q "CUSTOM_MARKER=do-not-clobber" "$HOME/.claude/second-brain.conf"
}

@test "second-brain.conf: installed from template on first run" {
  rm -f "$HOME/.claude/second-brain.conf"
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.claude/second-brain.conf" ]
  grep -q "^OBSIDIAN_VAULT_DIR=" "$HOME/.claude/second-brain.conf"
}

@test "CLAUDE.md: not overwritten if an existing one differs" {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/CLAUDE.md" <<'EOF'
My own custom global instructions, unrelated to this repo's CLAUDE.md.
EOF
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  grep -q "My own custom global instructions" "$HOME/.claude/CLAUDE.md"
}

@test "CLAUDE.md: installed fresh when none exists yet" {
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  diff -q "$REPO_ROOT/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
}
