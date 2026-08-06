#!/usr/bin/env bats
# Tests claude/hooks/synapse-prompt-context.sh -- the UserPromptSubmit nudge.
#
# It used to search the vault and inject matching node paths; measured against a
# real 52-node namespace it returned 50 of them for ~1057 tokens per turn, so the
# search was removed and the reminder kept. These tests therefore assert the
# opposite of what they used to: the same guards, but a SHORT constant line and
# no network call at all. The curl stub is still asserted -- as never being
# reached.

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

@test "namespace present: one short line naming the namespace and node count" {
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "$(repo_name)" "Cached backend.md" "Cached_backend invalidates query results."
  write_node "$(repo_name)" "Query API.md" "Conditions and validation."

  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"$(repo_name)"* ]]
  [[ "$ctx" == *"2 nodes"* ]]     # Index.md is the map, not a node
  [[ "$ctx" == *"synapse-query.sh"* ]]
}

@test "the nudge never lists nodes, and stays small enough to pay every turn" {
  # The whole reason the search was removed. A per-turn injection is charged on
  # every turn including ones with nothing to do with the codebase, so its size
  # is the feature. ~1057 tokens was the old cost; this pins the new one low and
  # pins that no node filename can creep back into it.
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  local i
  for i in $(seq 1 30); do
    write_node "$(repo_name)" "Node $i.md" "Body of node $i."
  done

  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" != *"Node 1.md"* ]]
  [[ "$ctx" != *"Node 17.md"* ]]
  # Constant regardless of namespace size: 30 nodes must not cost more than 2.
  [ "${#ctx}" -lt 400 ]
}

@test "the same line regardless of what the prompt says" {
  # It is a standing reminder, not a search result. A conversational prompt gets
  # it too -- that is the cost of surviving compaction, and why it is one line.
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "$(repo_name)" "Cached backend.md" "Cached_backend invalidates query results."

  run run_hook "how does Cached_backend invalidate results" "$REPO"
  local a="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  run run_hook "what is your favorite pizza topping today" "$REPO"
  local b="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [ "$a" = "$b" ]
}

@test "no network call is ever made" {
  # The search endpoint was the only reason this hook needed the vault REST API,
  # a cert and an API key. None of that is reachable now, so a stubbed curl must
  # stay untouched -- and the hook must work with no plugin data present at all.
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "$(repo_name)" "Cached backend.md" "Cached_backend invalidates query results."
  rm -rf "$VAULT/.obsidian" "$HOME/.claude/obsidian-local-rest-api-ca.pem"

  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -s "$CURL_LOG" ]
}

@test "a namespace with an Index.md but no nodes says nothing" {
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
