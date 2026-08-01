#!/usr/bin/env bats
# Tests claude/bin/synapse-tags.sh -- the dumb/mechanical helper that looks
# up a file's extension in the Synapse grammar registry and, if usable,
# ensures the grammar is cloned + registered with tree-sitter and prints
# its `tags` output. Real `tree-sitter`/`git clone` are stubbed out by
# tests/fixtures/fake-bin/{tree-sitter,git} -- see those files for exactly
# what they simulate -- so these tests exercise the script's own control
# flow (registry lookup, exit-code contract, clone/registration
# idempotency) without a real tree-sitter install or network access.

load 'test_helper'

SCRIPT="$REPO_ROOT/claude/bin/synapse-tags.sh"

setup() {
  common_setup
  GRAMMARS_DIR="$TEST_HOME/grammars"
  REGISTRY="$HOME/.claude/synapse-grammars.conf"
  FAKE_TS_LOG="$TEST_HOME/ts.log"
  FAKE_GIT_LOG="$TEST_HOME/git.log"
  : > "$FAKE_TS_LOG"
  : > "$FAKE_GIT_LOG"
}

teardown() {
  common_teardown
}

write_registry() {
  printf '%s' "$1" > "$REGISTRY"
}

run_synapse_tags() {
  local file="$1"
  PATH="$FAKE_BIN:$PATH" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    FAKE_TS_LOG="$FAKE_TS_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    "$SCRIPT" "$file"
}

@test "tree-sitter not installed: exits 1, no output" {
  mkdir -p "$TEST_HOME/no-ts-bin"
  cp "$FAKE_BIN/git" "$TEST_HOME/no-ts-bin/git"
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run env PATH="$TEST_HOME/no-ts-bin:$PATH" SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" "$SCRIPT" "$TEST_HOME/sample.ml"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "file with no extension: exits 1" {
  printf 'no extension here\n' > "$TEST_HOME/noext"
  write_registry '{}'

  run run_synapse_tags "$TEST_HOME/noext"
  [ "$status" -eq 1 ]
}

@test "extension has no registry entry at all: exits 2 (needs discovery), no clone attempted" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{}'

  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_GIT_LOG" ]
}

@test "extension marked unsupported: exits 1, no clone attempted" {
  printf 'fn main() {}\n' > "$TEST_HOME/sample.rs"
  write_registry '{"rs": {"unsupported": true}}'

  run run_synapse_tags "$TEST_HOME/sample.rs"
  [ "$status" -eq 1 ]
  [ ! -s "$FAKE_GIT_LOG" ]
}

@test "known, never-cloned extension: clones the grammar, registers parser-directories, prints tags, exit 0" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE_NAME"* ]]

  grep -q "clone" "$FAKE_GIT_LOG"
  [ -d "$GRAMMARS_DIR/repos/tree-sitter-ocaml" ]

  run jq -e '."parser-directories" | index("'"$GRAMMARS_DIR"'/repos")' "$HOME/.config/tree-sitter/config.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "grammar already cloned: does not clone again" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'
  mkdir -p "$GRAMMARS_DIR/repos/tree-sitter-ocaml"

  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GIT_LOG" ]
}

@test "parser-directories already registered: stays a single entry, not duplicated" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 0 ]
  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 0 ]

  run jq '."parser-directories" | map(select(. == "'"$GRAMMARS_DIR"'/repos")) | length' "$HOME/.config/tree-sitter/config.json"
  [ "$output" = "1" ]
}
