#!/usr/bin/env bats
# Tests claude/hooks/second-brain-session-start.sh -- both the pre-existing
# index-injection behavior and the Synapse pointer check added for sb-001.
# Pure git + filesystem, no network.

load 'test_helper'

HOOK="$REPO_ROOT/claude/hooks/second-brain-session-start.sh"

setup() {
  common_setup
}

teardown() {
  common_teardown
}

run_hook() {
  local cwd="$1"
  printf '{"cwd":"%s"}' "$cwd" | bash "$HOOK"
}

@test "no vault index and no synapse namespace: no output at all" {
  make_repo
  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "vault index present, no synapse namespace: injects index only" {
  write_vault_index
  make_repo
  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Test index content."* ]]
  [[ "$ctx" != *"Synapse namespace"* ]]
}

@test "synapse namespace with matching remote: appends pointer line" {
  write_vault_index
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Synapse namespace for this repo: synapse/$(repo_name)/Index.md"* ]]
}

@test "synapse namespace with mismatched remote: skips pointer and says so" {
  write_vault_index
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "git@github.com:someone-else/unrelated.git"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"doesn't match"* ]]
  [[ "$ctx" == *"Skipping the pointer"* ]]
  [[ "$ctx" != *"Synapse namespace for this repo:"* ]]
}

@test "synapse namespace keyed by path fallback when repo has no remote" {
  write_vault_index
  make_repo # no remote
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Synapse namespace for this repo: synapse/$(repo_name)/Index.md"* ]]
}

@test "cwd outside any git repo: base index still injected, no synapse logic invoked" {
  write_vault_index
  local outside="$TEST_HOME/not-a-repo"
  mkdir -p "$outside"

  run run_hook "$outside"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Test index content."* ]]
  [[ "$ctx" != *"Synapse namespace"* ]]
}

@test "org-roam backend: injects org index, never runs the synapse check" {
  cat > "$HOME/.claude/second-brain.conf" <<EOF
BACKEND=org-roam
ORG_ROAM_DIR="$TEST_HOME/roam"
OBSIDIAN_VAULT_DIR="$VAULT"
EOF
  mkdir -p "$TEST_HOME/roam"
  cat > "$TEST_HOME/roam/index.org" <<'EOF'
* Index
Org test content.
EOF
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Org test content."* ]]
  [[ "$ctx" != *"Synapse namespace"* ]]
}
