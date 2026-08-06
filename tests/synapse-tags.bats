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

# Forwards every argument, not just the first: batch mode is invoked as
# `--paths <list>`, and dropping the second word silently turns that into the
# no-list form, which exits 1 -- a green-looking helper bug that reads as a
# script bug.
run_synapse_tags() {
  PATH="$FAKE_BIN:$PATH" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    FAKE_TS_LOG="$FAKE_TS_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    "$SCRIPT" "$@"
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

@test "--paths: one tree-sitter invocation for the whole list, output attributable" {
  # The point of batch mode: CLI startup dominates per-file cost, so N files must
  # cost ONE invocation. Asserted against the fake's log rather than by timing.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf 'let b = 2\n' > "$TEST_HOME/b.ml"
  printf 'let c = 3\n' > "$TEST_HOME/c.ml"
  printf '%s\n' "$TEST_HOME/a.ml" "$TEST_HOME/b.ml" "$TEST_HOME/c.ml" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^tags ' "$FAKE_TS_LOG")" -eq 1 ]
  # Attributable: a path line, then that path's tab-indented tags.
  [ "$(grep -c '^/' <<< "$output")" -eq 3 ]
  [ "$(grep -c '^	' <<< "$output")" -eq 3 ]
}

@test "--paths: batch passes no --scope, so a mixed list is inferred per file" {
  # Forcing a scope makes tree-sitter parse EVERY file as that language -- a
  # .gradle file in a Java-scoped batch is parsed as Java. Verified against the
  # real CLI; pinned here so batch mode never grows a --scope.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf '%s\n' "$TEST_HOME/a.ml" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [[ "$(grep '^tags ' "$FAKE_TS_LOG")" != *"--scope"* ]]
}

@test "--paths: an extension with no grammar is warned ONCE, and the rest still tag" {
  # One line per extension, not tree-sitter's eight lines per file, which is
  # unreadable at repo scale. And a missing grammar must not fail the batch: a
  # mixed repo nearly always has some language that works.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf 'x\n' > "$TEST_HOME/one.zzz"
  printf 'y\n' > "$TEST_HOME/two.zzz"
  printf '%s\n' "$TEST_HOME/a.ml" "$TEST_HOME/one.zzz" "$TEST_HOME/two.zzz" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'no grammar registered for .zzz' <<< "$output")" -eq 1 ]
  [ "$(grep -c '^/' <<< "$output")" -eq 1 ]
}

@test "--paths: a ONE-path list still gets a path line and indented tags" {
  # The real CLI changes shape here: two or more paths get path lines and
  # indentation, exactly one gets neither -- bare tags, identical to
  # single-file form. A chunk of one is the common case rather than a corner
  # (one source changed, re-tag it), and left un-normalised an attributing
  # caller reads the first tag line as a path, finds the real path missing, and
  # concludes the file could not be parsed. That shipped once already: it cached
  # a perfectly readable file as `unsupported: true` with no tags.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf '%s\n' "$TEST_HOME/a.ml" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [ "$(head -1 <<< "$output")" = "$TEST_HOME/a.ml" ]
  [ "$(grep -c '^	' <<< "$output")" -eq 1 ]
  [[ "$output" == *"FAKE_NAME"* ]]
}

@test "--paths: one path and many paths produce the same shape per file" {
  # Asserted as an equivalence rather than two separate expectations, so the
  # normalisation cannot drift in only one direction.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf 'let b = 2\n' > "$TEST_HOME/b.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  printf '%s\n' "$TEST_HOME/a.ml" > "$TEST_HOME/one.txt"
  run run_synapse_tags --paths "$TEST_HOME/one.txt"
  [ "$status" -eq 0 ]
  local alone="$output"

  printf '%s\n%s\n' "$TEST_HOME/a.ml" "$TEST_HOME/b.ml" > "$TEST_HOME/two.txt"
  run run_synapse_tags --paths "$TEST_HOME/two.txt"
  [ "$status" -eq 0 ]
  # a.ml's slice of the two-path output: its path line plus the indented lines
  # up to the next unindented one.
  local together
  together="$(awk -v p="$TEST_HOME/a.ml" '
    $0 == p { on = 1; print; next }
    on && /^\t/ { print; next }
    on { exit }' <<< "$output")"
  [ "$alone" = "$together" ]
}

@test "--paths: a one-path list whose extension has no grammar still exits 1" {
  # The normalisation must not manufacture a path line for a file that was
  # never parseable -- that would turn "no grammar" into "parsed, no tags",
  # which is exactly the distinction `unsupported` rests on.
  printf 'x\n' > "$TEST_HOME/one.zzz"
  printf '%s\n' "$TEST_HOME/one.zzz" > "$TEST_HOME/list.txt"
  write_registry '{}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 1 ]
  [ -z "$(grep -v '^synapse-tags:' <<< "$output")" ]
}

@test "--paths: no usable grammar for anything in the list exits 1" {
  printf 'x\n' > "$TEST_HOME/one.zzz"
  printf '%s\n' "$TEST_HOME/one.zzz" > "$TEST_HOME/list.txt"
  write_registry '{}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 1 ]
}

@test "--paths: a missing list file exits 1 rather than tagging nothing quietly" {
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'
  run run_synapse_tags --paths "$TEST_HOME/nope.txt"
  [ "$status" -eq 1 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "--paths: the extension scan forks nothing per file" {
  # The trap this change exists to remove, reintroduced once already inside it:
  # `ext_of` calls basename, so scanning extensions in a loop cost 4.4s for 200
  # files against 0.08s for the tagging. Asserted structurally -- a per-path
  # basename in the batch path is the regression.
  run grep -c 'ext_of "$p"' "$REPO_ROOT/claude/bin/synapse-tags.sh"
  [ "$output" = "0" ]
}
