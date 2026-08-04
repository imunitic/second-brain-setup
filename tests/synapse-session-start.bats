#!/usr/bin/env bats
# Tests claude/hooks/synapse-session-start.sh -- both the pre-existing
# index-injection behavior and the Synapse pointer check added for sb-001.
# Pure git + filesystem, no network.

load 'test_helper'

HOOK="$REPO_ROOT/claude/hooks/synapse-session-start.sh"

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

@test "no OBSIDIAN_VAULT_DIR configured: no output, synapse check skipped" {
  cat > "$HOME/.claude/synapse.conf" <<'EOF'
EOF
  make_repo "git@github.com:example/repo.git"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- namespace catalogue (sb-001 multi-repo discovery) ----------------------
# One session routinely spans several repos, so the hook announces the *other*
# namespaces too, not just the cwd repo's. Built per session and stored
# nowhere: source of truth is the directory listing plus each Index.md's
# `remote:` field.

# Writes a namespace Index.md for a repo name that need not exist on disk.
write_foreign_namespace() {
  mkdir -p "$VAULT/synapse/$1"
  cat > "$VAULT/synapse/$1/Index.md" <<EOF2
---
title: "$1 — Synapse index"
node_type: synapse-index
project: $1
remote: "$2"
built_at: "test"
---
# $1 — Synapse index
EOF2
}

# $output is the hook's raw JSON, so the injected text is one line with
# escaped newlines. Decode it before doing anything line-oriented.
context() {
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'
}

catalogue_lines() {
  context | sed -n '/^Other Synapse namespaces/,$p' | sed '1d' | sed '/^$/d'
}

@test "catalogue: other namespaces are listed, the cwd repo's own is not" {
  make_repo
  write_vault_index
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_foreign_namespace "syrius3" "ssh://git@example.com/syrius3.git"
  write_foreign_namespace "syrius-querschnitt-basis" "ssh://git@example.com/qst.git"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Other Synapse namespaces in this vault"* ]]
  [[ "$output" == *"syrius3|ssh://git@example.com/syrius3.git"* ]]
  [[ "$output" == *"syrius-querschnitt-basis|ssh://git@example.com/qst.git"* ]]
  # own namespace excluded -- it already got the verified pointer above
  [ "$(catalogue_lines | cut -d'|' -f1 | grep -cx "$(repo_name)" || true)" = "0" ]
}

@test "catalogue: only the cwd repo has a namespace, so no catalogue is emitted" {
  make_repo
  write_vault_index
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Other Synapse namespaces"* ]]
  # the pointer itself is unaffected
  [[ "$output" == *"Synapse namespace for this repo"* ]]
}

@test "catalogue: no synapse/ directory at all means nothing extra is emitted" {
  make_repo
  write_vault_index

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Other Synapse namespaces"* ]]
}

@test "catalogue: ordering is LC_ALL=C sorted, not directory creation order" {
  make_repo
  write_vault_index
  # created in deliberately non-alphabetical order
  write_foreign_namespace "zzz-last" "ssh://git@example.com/z.git"
  write_foreign_namespace "mmm-middle" "ssh://git@example.com/m.git"
  write_foreign_namespace "aaa-first" "ssh://git@example.com/a.git"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  [ "$(catalogue_lines | sed -n 1p | cut -d'|' -f1)" = "aaa-first" ]
  [ "$(catalogue_lines | sed -n 2p | cut -d'|' -f1)" = "mmm-middle" ]
  [ "$(catalogue_lines | sed -n 3p | cut -d'|' -f1)" = "zzz-last" ]
}

@test "catalogue: outside any git repo, every namespace is listed and no pointer is emitted" {
  local outside="$TEST_HOME/not-a-repo"
  mkdir -p "$outside"
  write_vault_index
  write_foreign_namespace "fw-core" "ssh://git@example.com/fw.git"
  write_foreign_namespace "syrius3" "ssh://git@example.com/syrius3.git"

  run run_hook "$outside"
  [ "$status" -eq 0 ]
  # nothing to exclude, so both appear
  [[ "$output" == *"fw-core|"* ]]
  [[ "$output" == *"syrius3|"* ]]
  [[ "$output" != *"Synapse namespace for this repo"* ]]
}

@test "catalogue: emitted even when the vault has no Index.md to inject" {
  make_repo
  write_foreign_namespace "syrius3" "ssh://git@example.com/syrius3.git"

  run run_hook "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"syrius3|"* ]]
}

@test "the stop-nudge hook cites a CLAUDE.md heading that actually exists" {
  # The nudge text points the reader at a section of the global CLAUDE.md by name.
  # Renaming the heading without the hook (or the reverse) leaves a pointer to a
  # section that is not there, and nothing about reading the nudge would reveal it
  # -- the whole failure is silent. This caught nothing when written; it exists so
  # the next rename cannot break the pair.
  local nudge="$REPO_ROOT/claude/hooks/synapse-stop-nudge.sh"
  local cited
  cited="$(grep -o 'CLAUDE.md \\"[^\\]*\\" section' "$nudge" | sed -e 's/.*\\"\(.*\)\\" section/\1/')"
  [ -n "$cited" ]
  grep -qxF "# $cited" "$REPO_ROOT/claude/CLAUDE.md"
}
