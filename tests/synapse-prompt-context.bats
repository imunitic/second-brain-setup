#!/usr/bin/env bats
# Tests claude/hooks/synapse-prompt-context.sh (UserPromptSubmit per-prompt
# context injection, sb-004). The Obsidian Local REST API is stubbed by
# tests/fixtures/fake-bin/curl's glob+regexp branch (added for this hook) --
# see that file's comment for exactly what it simulates.

load 'test_helper'

HOOK="$REPO_ROOT/claude/hooks/synapse-prompt-context.sh"

write_node() {
  local project="$1" name="$2" content="$3"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/$name" <<EOF
---
title: "$name"
---
$content
EOF
}

setup() {
  common_setup
  setup_fake_obsidian_plugin
  cp "$REPO_ROOT/claude/synapse-prompt-stopwords.conf.template" \
    "$HOME/.claude/synapse-prompt-stopwords.conf"
  # The hook calls the *installed* tokenizer at ~/.claude/bin/, matching what
  # setup.sh actually puts there -- the repo copy at claude/bin/ is a different
  # path and the hook has no reason to know about it.
  mkdir -p "$HOME/.claude/bin"
  cp "$REPO_ROOT/claude/bin/synapse-tokenizer.sh" "$HOME/.claude/bin/synapse-tokenizer.sh"
  chmod +x "$HOME/.claude/bin/synapse-tokenizer.sh"
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
}

teardown() {
  common_teardown
}

run_hook() {
  local prompt="$1" cwd="$2"
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_CURL_LOG="$CURL_LOG"
  export FAKE_CURL_VAULT_DIR="$VAULT"
  # A temp file, not a pipe: the hook's disable check is its literal first
  # line, so a disabled run exits before ever reading stdin. Piping jq's
  # output straight in races the hook's exit against jq's write -- confirmed
  # on CI (both runners) as "jq: error: writing output failed: Broken pipe",
  # merged into $output by bats' run and failing the "no output" assertion.
  # Writing to a file first and redirecting it as stdin has no such race.
  local input="$BATS_TEST_TMPDIR/hook-input.json"
  jq -n --arg prompt "$prompt" --arg cwd "$cwd" '{prompt: $prompt, cwd: $cwd}' > "$input"
  bash "$HOOK" < "$input"
}

@test "disabled via env var: no output, no API call at all" {
  make_repo
  # Exported directly rather than as a `VAR=1 run ...` prefix -- prefix
  # assignment before invoking a function is not reliably propagated through
  # bats' own `run` wrapper across bats/bash versions.
  export SYNAPSE_DISABLE_PROMPT_INJECTION=1
  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CURL_LOG" ]
}

@test "no Synapse namespace for this repo: no-op" {
  make_repo
  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "namespace exists, remote mismatches: no-op" {
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "git@github.com:someone-else/unrelated.git"
  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "matching node: additionalContext lists it" {
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "$(repo_name)" "Cached backend.md" "Cached_backend invalidates query results when a component changes."

  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Cached backend.md"* ]]
}

@test "prompt matching nothing in the namespace: silent" {
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "$(repo_name)" "Cached backend.md" "Cached_backend invalidates query results when a component changes."

  run run_hook "what is your favorite pizza topping today" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "purely conversational prompt: no distinctive terms extracted, no API call" {
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "$(repo_name)" "Cached backend.md" "Cached_backend invalidates query results."

  run run_hook "how are you doing" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CURL_LOG" ]
}
