#!/usr/bin/env bats
# Tests `synapse-query.sh grounding` -- verification of the evidence a summary
# rests on. The point of the subcommand is the distinction it draws: a grounding
# whose text merely MOVED is mechanically re-pointable and needs no reading,
# while one whose text CHANGED is a claim to go re-check. A check that reported
# both identically would be ignored within a week, because inserting a line
# anywhere near the top of a file shifts every grounding below it.

load 'test_helper'

QUERY="$REPO_ROOT/claude/bin/synapse-query.sh"
WRITER="$REPO_ROOT/claude/bin/synapse-write-node.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  BODY="$TEST_HOME/body.md"
  PATHS="$TEST_HOME/paths.txt"
}

teardown() { common_teardown; }

in_repo() {
  PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$@"
}

ns() { echo "$VAULT/synapse/$(repo_name)"; }

# A node grounded in a two-line doc comment at the top of calc.ml.
build_grounded_node() {
  make_repo
  mkdir -p "$REPO/lib"
  { printf '(* Computes the premium for a contract.\n'
    printf '   Rounds half-up at two decimals. *)\n'
    for i in $(seq 3 12); do printf 'let line%02d = %d\n' "$i" "$i"; done; } > "$REPO/lib/calc.ml"
  git -C "$REPO" add lib/calc.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m calc
  printf 'src/foo.ml\nlib/calc.ml\n' > "$PATHS"
  printf '## Summary\nRounds half-up at two decimals.\n<!-- grounded_in: lib/calc.ml 1-2 -->\n' > "$BODY"

  in_repo "$WRITER" --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$BODY" >/dev/null
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  printf '{"lib/calc.ml":["Premium.md"],"src/foo.ml":["Premium.md"],"_unassigned":[]}' \
    > "$(ns)/_index.json"
}

@test "grounding: silence when every recorded grounding still matches" {
  build_grounded_node
  run in_repo "$QUERY" grounding
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "grounding: an unrelated edit elsewhere in the file stays silent" {
  build_grounded_node
  # Appending below the grounded range must not disturb it -- this is what
  # digesting the slice rather than the file buys.
  printf 'let tail = 99\n' >> "$REPO/lib/calc.ml"
  run in_repo "$QUERY" grounding
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "grounding: a pure line shift is reported as moved, with the new range" {
  build_grounded_node
  # Two lines inserted above: the doc comment is now at 3-4, byte-identical.
  printf '(* new header *)\n(* second line *)\n' > "$TEST_HOME/pre"
  cat "$REPO/lib/calc.ml" >> "$TEST_HOME/pre"
  mv "$TEST_HOME/pre" "$REPO/lib/calc.ml"

  run in_repo "$QUERY" grounding
  [ "$status" -eq 0 ]
  [[ "$output" == *"grounding moved"* ]]
  [[ "$output" == *"1-2 -> 3-4"* ]]
  [[ "$output" != *"grounding changed"* ]]
}

@test "grounding: an edit to the grounded text itself is reported as changed" {
  build_grounded_node
  # The claim the summary rests on is now different prose.
  sed_i 's/Rounds half-up at two decimals/Truncates toward zero/' "$REPO/lib/calc.ml"

  run in_repo "$QUERY" grounding
  [ "$status" -eq 0 ]
  [[ "$output" == *"grounding changed"* ]]
  [[ "$output" == *"lib/calc.ml 1-2"* ]]
  [[ "$output" == *"re-check the claim"* ]]
  [[ "$output" != *"grounding moved"* ]]
}

@test "grounding: a deleted grounding file is named" {
  build_grounded_node
  rm "$REPO/lib/calc.ml"
  run in_repo "$QUERY" grounding
  [ "$status" -eq 0 ]
  [[ "$output" == *"grounding file gone: lib/calc.ml"* ]]
}

@test "grounding: a node with no grounded_in is silently skipped" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"
  printf '## Summary\nUngrounded.\n' > "$BODY"
  in_repo "$WRITER" --title "Plain" --summary "S." --paths "$PATHS" --body "$BODY" >/dev/null
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  printf '{"src/foo.ml":["Plain.md"],"_unassigned":[]}' > "$(ns)/_index.json"

  run in_repo "$QUERY" grounding
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "grounding: refuses on a remote mismatch rather than reporting clean" {
  build_grounded_node
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  run in_repo "$QUERY" grounding
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "grounding: takes no arguments" {
  build_grounded_node
  run in_repo "$QUERY" grounding extra
  [ "$status" -eq 2 ]
}

@test "grounding --list: prints the recorded pointers, so a rebuild can re-emit them" {
  build_grounded_node
  run in_repo "$QUERY" grounding "Premium" --list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'lib/calc.ml\t1-2')" ]
}

@test "grounding --list: the digest is not printed, only what a directive needs" {
  build_grounded_node
  run in_repo "$QUERY" grounding "Premium.md" --list
  [ "$status" -eq 0 ]
  # a directive needs path and lines; the digest is the writer's to recompute
  [ "$(printf '%s' "$output" | awk -F'\t' '{print NF}')" -eq 2 ]
}

@test "grounding --list: a node without groundings prints nothing, exit 0" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"
  printf '## Summary\nUngrounded.\n' > "$BODY"
  in_repo "$WRITER" --title "Bare" --summary "S." --paths "$PATHS" --body "$BODY" >/dev/null
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run in_repo "$QUERY" grounding "Bare" --list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "grounding --list: an unknown node exits 1" {
  build_grounded_node
  run in_repo "$QUERY" grounding "Nope" --list
  [ "$status" -eq 1 ]
}

@test "round trip: --list plus re-emit preserves groundings; omitting them loses all" {
  build_grounded_node
  # What a regeneration actually has in hand: the prose, with no directives in it.
  in_repo "$QUERY" body "Premium" | awk '/^## Sources$/ { exit } { print }' > "$TEST_HOME/recovered.md"
  ! grep -q 'grounded_in' "$TEST_HOME/recovered.md"

  # (a) writing the recovered body back as-is drops the provenance, silently
  in_repo "$WRITER" --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$TEST_HOME/recovered.md" >/dev/null
  ! grep -q '^grounded_in:' "$(ns)/Premium.md"

  # (b) re-emitting from --list restores it exactly -- which is why --list exists
  cp "$TEST_HOME/recovered.md" "$TEST_HOME/reemit.md"
  while IFS="$(printf '\t')" read -r p l; do
    printf '<!-- grounded_in: %s %s -->\n' "$p" "$l" >> "$TEST_HOME/reemit.md"
  done < <(printf 'lib/calc.ml\t1-2\n')

  in_repo "$WRITER" --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$TEST_HOME/reemit.md" >/dev/null
  grep -qxF '  - path: lib/calc.ml' "$(ns)/Premium.md"
  grep -qxF '    lines: "1-2"' "$(ns)/Premium.md"
  run in_repo "$QUERY" grounding
  [ -z "$output" ]
}
