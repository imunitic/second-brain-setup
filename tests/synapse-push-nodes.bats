#!/usr/bin/env bats
# Tests claude/bin/synapse-push-nodes.sh -- the driver that pairs each authored
# body with its path list and calls the writer once per node.

load 'test_helper'

PUSH="$REPO_ROOT/claude/bin/synapse-push-nodes.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK/lists"
  make_repo
  mkdir -p "$REPO/mod-a" "$REPO/docs"
  printf 'a\n' > "$REPO/mod-a/a.txt"
  printf 'd\n' > "$REPO/docs/d.md"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m files
}

teardown() {
  common_teardown
}

run_push() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_PUT_STATUS="${PUT_STATUS:-200}" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$PUSH" "$@"
}

# Sets up node NN with a title, a one-path list and a body.
stage_node() {
  local nn="$1" title="$2" path="$3"
  printf '%s\n' "$title" > "$WORK/lists/$nn.title"
  printf '%s\n' "$path" > "$WORK/lists/$nn.txt"
  printf -- '---\nsummary: Node %s in one line.\n---\n\n## Summary\nNode %s.\n' "$nn" "$nn" > "$WORK/b-$nn.md"
}

node_file() { echo "$VAULT/synapse/$(repo_name)/$1.md"; }

@test "pushes every node that has both a list and a body" {
  stage_node 01 "Mod A" mod-a/a.txt
  stage_node 02 "Docs" docs/d.md

  run run_push
  [ "$status" -eq 0 ]
  [ -f "$(node_file "Mod A")" ]
  [ -f "$(node_file Docs)" ]
  # Each line reports the node number alongside the writer's own output.
  [[ "$output" == *"01	Mod A.md"* ]]
  [[ "$output" == *"02	Docs.md"* ]]
}

@test "explicit node numbers restrict the push" {
  stage_node 01 "Mod A" mod-a/a.txt
  stage_node 02 "Docs" docs/d.md

  run run_push 02
  [ "$status" -eq 0 ]
  [ -f "$(node_file Docs)" ]
  [ ! -f "$(node_file "Mod A")" ]
}

@test "a list with no authored body is skipped, not written empty" {
  stage_node 01 "Mod A" mod-a/a.txt
  printf 'Docs\n' > "$WORK/lists/02.title"
  printf 'docs/d.md\n' > "$WORK/lists/02.txt"

  run run_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"02	SKIP (no body)"* ]]
  [ ! -f "$(node_file Docs)" ]
}

@test "a body with no list is skipped rather than pushed with empty sources" {
  stage_node 01 "Mod A" mod-a/a.txt
  printf -- '---\nsummary: Orphan.\n---\n\n## Summary\nOrphan.\n' > "$WORK/b-07.md"

  run run_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"07	SKIP (no list/title)"* ]]
}

@test "one failing node is reported and the rest still push" {
  stage_node 01 "Mod A" mod-a/a.txt
  # A list naming a path that no longer exists makes the writer refuse.
  printf 'Broken\n' > "$WORK/lists/02.title"
  printf 'docs/gone.md\n' > "$WORK/lists/02.txt"
  printf -- '---\nsummary: Broken.\n---\n\n## Summary\nBroken.\n' > "$WORK/b-02.md"
  stage_node 03 "Docs" docs/d.md

  run run_push
  [ "$status" -eq 1 ]
  [[ "$output" == *"02	FAILED"* ]]
  [[ "$output" == *"1 node(s) failed"* ]]
  # The failure must not abort the run: 03 comes after 02 and must still exist.
  [ -f "$(node_file Docs)" ]
  [ -f "$(node_file "Mod A")" ]
}

@test "the writer is resolved as a sibling, not from PATH" {
  stage_node 01 "Mod A" mod-a/a.txt
  # A decoy earlier on PATH must be ignored: an installed copy has to find the
  # writer it shipped with, not whatever happens to be callable.
  mkdir -p "$TEST_HOME/decoy"
  printf '#!/bin/bash\necho DECOY RAN\nexit 0\n' > "$TEST_HOME/decoy/synapse-write-node.sh"
  chmod +x "$TEST_HOME/decoy/synapse-write-node.sh"

  run env PATH="$TEST_HOME/decoy:$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$PUSH"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DECOY RAN"* ]]
  [ -f "$(node_file "Mod A")" ]
}

@test "no bodies at all exits 1 instead of reporting a silent success" {
  printf 'Mod A\n' > "$WORK/lists/01.title"
  printf 'mod-a/a.txt\n' > "$WORK/lists/01.txt"

  run run_push
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing to push"* ]]
}

@test "the summary comes from the body's frontmatter and is stripped from the prose" {
  stage_node 01 "Mod A" mod-a/a.txt

  run run_push
  [ "$status" -eq 0 ]

  local f; f="$(node_file "Mod A")"
  # Everything authored about a node lives in one b-NN.md: its headline becomes the
  # node's `summary` field...
  grep -q '^summary: "Node 01 in one line\."$' "$f"
  # ...and must not be repeated inside the prose.
  ! grep -q 'summary: Node 01 in one line' "$(printf '%s' "$f")"
  [ "$(grep -c '^summary:' "$f")" -eq 1 ]
  grep -q '^## Summary$' "$f"
  grep -q '^Node 01\.$' "$f"
}

@test "a body with no summary frontmatter fails rather than writing a node without one" {
  printf 'Mod A\n' > "$WORK/lists/01.title"
  printf 'mod-a/a.txt\n' > "$WORK/lists/01.txt"
  printf '## Summary\nNo frontmatter here.\n' > "$WORK/b-01.md"

  run run_push
  [ "$status" -eq 1 ]
  [[ "$output" == *'01	FAILED (no `summary:` frontmatter in b-01.md)'* ]]
  # The index is built from node summaries, so a node without one would break it
  # later; better to fail at the point the author can fix it.
  [ ! -f "$(node_file "Mod A")" ]
}

@test "a missing lists directory points at the step that produces it" {
  rm -rf "$WORK/lists"
  printf -- '---\nsummary: x.\n---\n\n## Summary\nx\n' > "$WORK/b-01.md"

  run run_push
  [ "$status" -eq 1 ]
  [[ "$output" == *"synapse-build-lists.sh first"* ]]
}
