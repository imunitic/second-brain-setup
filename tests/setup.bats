#!/usr/bin/env bats
# Tests setup.sh: installs the portable tooling into $HOME/.claude and
# merges hook wiring into settings.json. Runs entirely against a scratch
# $HOME -- never touches the real ~/.claude.

load 'test_helper'

SETUP_SH="$REPO_ROOT/setup.sh"

setup() {
  common_setup
  # setup.sh writes its own synapse.conf if missing; common_setup
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
  [ -f "$HOME/.claude/hooks/synapse-session-start.sh" ]
  [ -x "$HOME/.claude/hooks/synapse-session-start.sh" ]

  [ -f "$HOME/.claude/commands/synapse-init.md" ]
  [ -f "$HOME/.claude/commands/synapse-note.md" ]
  [ -f "$HOME/.claude/commands/synapse-design-note.md" ]
  [ -f "$HOME/.claude/commands/synapse-task-note.md" ]
  [ -f "$HOME/.claude/skills/synapse-node/SKILL.md" ]
  [ -f "$HOME/.claude/skills/synapse-task/SKILL.md" ]
  [ -f "$HOME/.claude/skills/synapse-query/SKILL.md" ]

  # The knowledge skills. Asserted by name because the failure this guards against is
  # one of them silently not installing -- the same shape as the bin/ script that was
  # missed until the installer globbed instead of naming each file, which is now also
  # how skills are installed.
  [ -f "$HOME/.claude/skills/synapse-node-format/SKILL.md" ]
  [ -f "$HOME/.claude/skills/synapse-orientation/SKILL.md" ]

  # Every skill in the repo installs, without the installer naming any of them. This
  # is the assertion that would have caught a new skill being added and forgotten.
  for d in "$REPO_ROOT"/claude/skills/*/; do
    [ -f "$HOME/.claude/skills/$(basename "$d")/SKILL.md" ]
  done

  [ -f "$HOME/.claude/bin/synapse-tags.sh" ]
  [ -x "$HOME/.claude/bin/synapse-tags.sh" ]

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

  [ "$(hook_count "bash ~/.claude/hooks/synapse-session-start.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-db-sync.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-staleness.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-stop-nudge.sh")" = "1" ]
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

  [ "$(hook_count "bash ~/.claude/hooks/synapse-session-start.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-db-sync.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-staleness.sh")" = "1" ]
  [ "$(hook_count "bash ~/.claude/hooks/synapse-stop-nudge.sh")" = "1" ]
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

@test "synapse.conf: left untouched if it already exists" {
  cat > "$HOME/.claude/synapse.conf" <<'EOF'
OBSIDIAN_VAULT_DIR="/some/custom/path"
CUSTOM_MARKER=do-not-clobber
EOF
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  grep -q "CUSTOM_MARKER=do-not-clobber" "$HOME/.claude/synapse.conf"
}

@test "synapse.conf: installed from template on first run" {
  rm -f "$HOME/.claude/synapse.conf"
  run bash "$SETUP_SH"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.claude/synapse.conf" ]
  grep -q "^OBSIDIAN_VAULT_DIR=" "$HOME/.claude/synapse.conf"
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

# --- config rename migration ------------------------------------------------
# The migration is the part that touches a machine someone already set up, so
# it is the part most worth pinning: a fresh template landing beside a real
# config would silently lose the vault path, and the loss is invisible until
# something goes looking for the vault.

@test "migration: an existing second-brain.conf is moved, keeping its contents" {
  rm -f "$HOME/.claude/synapse.conf"
  cat > "$HOME/.claude/second-brain.conf" <<'EOF'
OBSIDIAN_VAULT_DIR="/somewhere/real"
EOF

  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"renamed (project rename): second-brain.conf -> synapse.conf"* ]]
  [ ! -e "$HOME/.claude/second-brain.conf" ]
  # the real value survives -- not replaced by the template
  grep -qxF 'OBSIDIAN_VAULT_DIR="/somewhere/real"' "$HOME/.claude/synapse.conf"
}

@test "migration: second-brain-projects.conf is moved too" {
  rm -f "$HOME/.claude/synapse-projects.conf"
  printf 'eon=ecs\n' > "$HOME/.claude/second-brain-projects.conf"

  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/second-brain-projects.conf" ]
  grep -qxF 'eon=ecs' "$HOME/.claude/synapse-projects.conf"
}

@test "migration: both names present warns and prefers the new one" {
  printf 'OBSIDIAN_VAULT_DIR="/new"\n' > "$HOME/.claude/synapse.conf"
  printf 'OBSIDIAN_VAULT_DIR="/old"\n' > "$HOME/.claude/second-brain.conf"

  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING both second-brain.conf and synapse.conf exist"* ]]
  # neither is clobbered: the human is told to merge, not silently overruled
  grep -qxF 'OBSIDIAN_VAULT_DIR="/new"' "$HOME/.claude/synapse.conf"
  grep -qxF 'OBSIDIAN_VAULT_DIR="/old"' "$HOME/.claude/second-brain.conf"
}

@test "migration: is idempotent -- a second run reports nothing to rename" {
  rm -f "$HOME/.claude/synapse.conf"
  printf 'OBSIDIAN_VAULT_DIR="/x"\n' > "$HOME/.claude/second-brain.conf"
  run bash "$REPO_ROOT/setup.sh"
  [[ "$output" == *"renamed (project rename)"* ]]
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"renamed (project rename)"* ]]
  [[ "$output" != *"WARNING both"* ]]
}

@test "stale: pre-rename sb- commands and skill are warned about, loudly" {
  # These do not merely linger: a leftover commands/sb-note.md still registers as
  # /sb-note, so the user sees two of everything with only one maintained.
  mkdir -p "$HOME/.claude/commands" "$HOME/.claude/skills/sb-task"
  printf '# old\n' > "$HOME/.claude/commands/sb-note.md"
  printf '# old\n' > "$HOME/.claude/skills/sb-task/SKILL.md"

  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-rename copies"* ]]
  [[ "$output" == *"sb-note.md"* ]]
  [[ "$output" == *"skills/sb-task/"* ]]
  [[ "$output" == *"you will see both"* ]]
  # and the new ones are installed regardless
  [ -f "$HOME/.claude/commands/synapse-note.md" ]
  [ -f "$HOME/.claude/skills/synapse-task/SKILL.md" ]
}

@test "stale: no warning on a clean install" {
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pre-rename copies"* ]]
}

# --- hook rename: settings.json path migration ------------------------------
# The hardest part of renaming a hook: settings.json references it by path, and
# this installer copies in without deleting. Add-if-missing alone would leave the
# old entry beside the new one, both pointing at files that exist, and every hook
# would fire twice -- two index injections, two nudges, two vault commits.

cmds() { # cmds <event> -- every command string wired for that hook event
  jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command' "$HOME/.claude/settings.json"
}

@test "hook rename: pre-rename settings entries are rewritten, not duplicated" {
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-session-start.sh"}]}],
    "PostToolUse": [{"matcher":"Write|Edit","hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-db-sync.sh"}]}],
    "Stop": [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-stop-nudge.sh"}]}]
  }
}
EOF
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]

  [ "$(cmds SessionStart | grep -c 'synapse-session-start.sh')" -eq 1 ]
  [ "$(cmds Stop | grep -c 'synapse-stop-nudge.sh')" -eq 1 ]
  [ "$(cmds PostToolUse | grep -c 'synapse-db-sync.sh')" -eq 1 ]
  # nothing anywhere still points at the old names
  ! grep -q 'second-brain-' "$HOME/.claude/settings.json"
}

@test "hook rename: an old and a new entry collapse to one" {
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {"hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-stop-nudge.sh"}]},
      {"hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-stop-nudge.sh"}]}
    ]
  }
}
EOF
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  # two entries that become identical would otherwise fire the nudge twice
  [ "$(cmds Stop | grep -c 'synapse-stop-nudge.sh')" -eq 1 ]
}

@test "hook rename: unrelated settings with a 'command' field are untouched" {
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "statusLine": {"type":"command","command":"npx -y ccstatusline@latest"},
  "env": {"KEEP":"me"},
  "hooks": {
    "SessionStart": [
      {"hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-session-start.sh"}]},
      {"hooks":[{"type":"command","command":"/Users/me/.claude/hooks/my-own-hook.sh"}]}
    ]
  }
}
EOF
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.statusLine.command' "$HOME/.claude/settings.json")" = "npx -y ccstatusline@latest" ]
  [ "$(jq -r '.env.KEEP' "$HOME/.claude/settings.json")" = "me" ]
  # somebody else's hook survives the migration untouched
  cmds SessionStart | grep -qF '/Users/me/.claude/hooks/my-own-hook.sh'
}

@test "hook rename: migration is idempotent" {
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/second-brain-stop-nudge.sh"}]}]}}
EOF
  bash "$REPO_ROOT/setup.sh" >/dev/null
  local first; first="$(cmds Stop | grep -c 'synapse-stop-nudge.sh')"
  bash "$REPO_ROOT/setup.sh" >/dev/null
  [ "$(cmds Stop | grep -c 'synapse-stop-nudge.sh')" -eq "$first" ]
  [ "$first" -eq 1 ]
}

@test "hook rename: leftover hook files are named as inert, not as still-wired" {
  mkdir -p "$HOME/.claude/hooks"
  printf '#!/bin/bash\n' > "$HOME/.claude/hooks/second-brain-db-sync.sh"
  run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no longer referenced by settings.json"* ]]
  [[ "$output" == *"second-brain-db-sync.sh"* ]]
}
