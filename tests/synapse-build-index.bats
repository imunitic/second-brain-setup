#!/usr/bin/env bats
# Tests claude/bin/synapse-build-index.sh -- the reverse index the PostToolUse
# staleness hook reads. Its two load-bearing properties are that it covers every
# enumerated path (an unlisted path silently flags nothing stale) and that its
# values are usable as vault paths verbatim, i.e. carry the `.md` extension.
#
# The PUT payload is captured by tests/fixtures/fake-bin/curl into
# $FAKE_CURL_CAPTURE_DIR/index-put.json, so assertions run against the real JSON.

load 'test_helper'

BUILD_INDEX="$REPO_ROOT/claude/bin/synapse-build-index.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  CAPTURE="$TEST_HOME/capture"
  mkdir -p "$WORK/lists" "$CAPTURE"
  : > "$WORK/unassigned.txt"
  make_repo
}

teardown() {
  common_teardown
}

run_build_index() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_CAPTURE_DIR="$CAPTURE" \
    FAKE_CURL_PUT_STATUS="${PUT_STATUS:-200}" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$BUILD_INDEX" "$@"
}

stage_list() {
  local nn="$1" title="$2"; shift 2
  printf '%s\n' "$title" > "$WORK/lists/$nn.title"
  printf '%s\n' "$@" > "$WORK/lists/$nn.txt"
}

index_json() { echo "$CAPTURE/index-put.json"; }

@test "maps each path to its owning node, with the .md extension" {
  stage_list 01 "Mod A" mod-a/a.txt mod-a/b.txt
  stage_list 02 "Docs" docs/d.md

  run run_build_index
  [ "$status" -eq 0 ]

  # The hook and the read-time procedure use this value directly as a vault path
  # with no extension handling of their own.
  [ "$(jq -r '."mod-a/a.txt"[0]' "$(index_json)")" = "Mod A.md" ]
  [ "$(jq -r '."mod-a/b.txt"[0]' "$(index_json)")" = "Mod A.md" ]
  [ "$(jq -r '."docs/d.md"[0]' "$(index_json)")" = "Docs.md" ]
}

@test "a file load-bearing for two concepts lists both nodes, sorted" {
  # Many-to-many is intentional in the design, not an oversight.
  stage_list 01 "Zeta" shared/thing.java
  stage_list 02 "Alpha" shared/thing.java

  run run_build_index
  [ "$status" -eq 0 ]
  [ "$(jq -r '."shared/thing.java" | length' "$(index_json)")" -eq 2 ]
  [ "$(jq -r '."shared/thing.java"[0]' "$(index_json)")" = "Alpha.md" ]
  [ "$(jq -r '."shared/thing.java"[1]' "$(index_json)")" = "Zeta.md" ]
}

@test "_unassigned carries what no node claimed" {
  stage_list 01 "Mod A" mod-a/a.txt
  printf 'stray.txt\n.claude/settings.json\n' > "$WORK/unassigned.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  [ "$(jq -r '._unassigned | length' "$(index_json)")" -eq 2 ]
  jq -e '._unassigned | index("stray.txt")' "$(index_json)" > /dev/null
  [[ "$output" == *"unassigned=2"* ]]
}

@test "an empty unassigned.txt yields an empty array, not a null or a blank entry" {
  stage_list 01 "Mod A" mod-a/a.txt
  : > "$WORK/unassigned.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  [ "$(jq -r '._unassigned | type' "$(index_json)")" = "array" ]
  [ "$(jq -r '._unassigned | length' "$(index_json)")" -eq 0 ]
}

@test "node values are sanitized to the filenames that actually exist on disk" {
  # The value has to match the file the writer produced, which is the sanitized
  # title -- an unsanitized value would point the hook at a nonexistent note.
  stage_list 01 "Bad — import/export" mod-a/a.txt

  run run_build_index
  [ "$status" -eq 0 ]
  [ "$(jq -r '."mod-a/a.txt"[0]' "$(index_json)")" = "Bad — import_export.md" ]
}

@test "blank lines in a list do not become empty keys" {
  printf 'Mod A\n' > "$WORK/lists/01.title"
  printf 'mod-a/a.txt\n\nmod-a/b.txt\n\n' > "$WORK/lists/01.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys | length' "$(index_json)")" -eq 3 ]  # 2 paths + _unassigned
  run jq -e 'has("")' "$(index_json)"
  [ "$status" -ne 0 ]
}

@test "a list with no matching .title file is skipped rather than keyed to '.md'" {
  stage_list 01 "Mod A" mod-a/a.txt
  printf 'orphan/path.txt\n' > "$WORK/lists/99.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  run jq -e 'has("orphan/path.txt")' "$(index_json)"
  [ "$status" -ne 0 ]
}

@test "reports key count and byte size so a truncated index is visible" {
  stage_list 01 "Mod A" mod-a/a.txt mod-a/b.txt
  run run_build_index
  [ "$status" -eq 0 ]
  [[ "$output" == *"keys=3"* ]]
  [[ "$output" == *"bytes="* ]]
}

@test "a non-2xx PUT fails and stores nothing" {
  stage_list 01 "Mod A" mod-a/a.txt

  PUT_STATUS=500 run run_build_index
  [ "$status" -eq 1 ]
  [[ "$output" == *"PUT failed (500)"* ]]
  [ ! -f "$(index_json)" ]
}

@test "missing lists, missing unassigned.txt and an empty lists dir each exit 1" {
  run run_build_index
  [ "$status" -eq 1 ]
  [[ "$output" == *"no (path, node) pairs"* ]]

  stage_list 01 "Mod A" mod-a/a.txt
  rm -f "$WORK/unassigned.txt"
  run run_build_index
  [ "$status" -eq 1 ]
  [[ "$output" == *"no unassigned.txt"* ]]

  : > "$WORK/unassigned.txt"
  rm -rf "$WORK/lists"
  run run_build_index
  [ "$status" -eq 1 ]
  [[ "$output" == *"no lists/"* ]]
}
