#!/usr/bin/env bats
# End-to-end test of the scripted /synapse-init pipeline:
#
#   synapse-build-lists.sh -> synapse-push-nodes.sh
#                          -> synapse-build-index.sh
#                          -> synapse-build-project-index.sh
#
# then reads the result back through synapse-query.sh, which is the only way the
# namespace is ever consumed. The per-script tests cover behaviour in isolation;
# this one exists because every bug that actually escaped review was an interface
# mismatch between two steps, invisible until the whole chain ran.
#
# The repo used here is deliberately unlike the one the scripts were developed
# against: no remote, a repo-root src/ tree, mixed languages, a binary file and a
# file no node claims.

load 'test_helper'

BIN="$REPO_ROOT/claude/bin"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  CAPTURE="$TEST_HOME/capture"
  mkdir -p "$WORK" "$CAPTURE"

  make_repo
  mkdir -p "$REPO/src/main/java/com/example" "$REPO/lib" "$REPO/docs" "$REPO/assets"
  printf 'class App {}\n' > "$REPO/src/main/java/com/example/App.java"
  printf 'class Util {}\n' > "$REPO/src/main/java/com/example/Util.java"
  printf 'let f x = x\n' > "$REPO/lib/core.ml"
  printf '# Guide\n' > "$REPO/docs/guide.md"
  printf '# Notes\n' > "$REPO/docs/notes.md"
  printf 'PNG\n' > "$REPO/assets/logo.png"
  printf 'orphan\n' > "$REPO/leftover.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m tree
}

teardown() {
  common_teardown
}

in_repo() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_CAPTURE_DIR="$CAPTURE" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$@"
}

# Runs all four steps. The fake curl captures an _index.json PUT to the capture
# dir rather than the vault tree, so it is copied into place afterwards -- the
# real REST API stores it in the vault, and `synapse-query.sh stale` reads it back
# from there.
run_pipeline() {
  printf 'Java — the application\t^src/\t\nDocs — the documentation\t^docs/\t\nOCaml — the library\t^lib/\t\n' > "$WORK/manifest.tsv"
  in_repo "$BIN/synapse-build-lists.sh" || return 1

  # Each authored body carries its own one-line summary in frontmatter; the driver
  # strips it and it becomes the node's `summary` field, which the index reads back.
  printf -- '---\nsummary: The java application.\n---\n\n## Summary\nThe java application.\n\n## Links\n- uses [[Docs — the documentation]]\n' > "$WORK/b-01.md"
  printf -- '---\nsummary: The documentation.\n---\n\n## Summary\nThe documentation.\n' > "$WORK/b-02.md"
  printf -- '---\nsummary: The ocaml library.\n---\n\n## Summary\nThe ocaml library.\n' > "$WORK/b-03.md"

  in_repo "$BIN/synapse-push-nodes.sh" || return 1
  in_repo "$BIN/synapse-build-index.sh" || return 1
  in_repo "$BIN/synapse-build-project-index.sh" || return 1

  mkdir -p "$VAULT/synapse/$(repo_name)"
  cp "$CAPTURE/index-put.json" "$VAULT/synapse/$(repo_name)/_index.json"
}

@test "the four steps produce a complete, self-consistent namespace" {
  run run_pipeline
  [ "$status" -eq 0 ]

  local ns="$VAULT/synapse/$(repo_name)"
  [ -f "$ns/Java — the application.md" ]
  [ -f "$ns/Docs — the documentation.md" ]
  [ -f "$ns/OCaml — the library.md" ]
  [ -f "$ns/Index.md" ]
  [ -f "$ns/_index.json" ]

  # Coverage: the binary file was dropped at enumeration, and the one text file no
  # node claimed is in _unassigned rather than lost.
  ! grep -q 'logo.png' "$WORK/all.txt"
  grep -q '^leftover.txt$' "$WORK/unassigned.txt"
  jq -e '._unassigned | index("leftover.txt")' "$ns/_index.json" > /dev/null

  # Every node in the index points at a file that exists -- the check that the
  # per-script tests cannot make.
  local node
  while IFS= read -r node; do
    [ -f "$ns/$node" ]
  done < <(jq -r 'to_entries | map(select(.key != "_unassigned")) | map(.value[]) | unique | .[]' "$ns/_index.json")
}

@test "every wikilink resolves, and every node is listed in Index.md" {
  run run_pipeline
  [ "$status" -eq 0 ]

  local ns="$VAULT/synapse/$(repo_name)" link f
  # A broken wikilink is a valid link to a not-yet-existing note, so it fails
  # silently in Obsidian -- the only way to catch it is exactly this check.
  while IFS= read -r link; do
    [ -f "$ns/$link.md" ]
  done < <(grep -ho '\[\[[^]]*\]\]' "$ns"/*.md | sed 's/^\[\[//; s/\]\]$//' | sort -u)

  # And the reverse: a node missing from the index is invisible to a reader.
  for f in "$ns"/*.md; do
    [ "$(basename "$f")" = "Index.md" ] && continue
    grep -q "\[\[$(basename "$f" .md)\]\]" "$ns/Index.md"
  done
}

@test "synapse-query.sh reads back what the pipeline wrote" {
  run run_pipeline
  [ "$status" -eq 0 ]

  # body prints the prose only -- no frontmatter, no ## Notes.
  run in_repo "$BIN/synapse-query.sh" body "Java — the application"
  [ "$status" -eq 0 ]
  [[ "$output" == *"The java application."* ]]
  [[ "$output" != *"sources_digest"* ]]
  [[ "$output" != *"## Notes"* ]]

  # Asserted against the list the node was built from, so the two cannot drift:
  # the ^src/ pattern also picks up the helper's src/foo.ml.
  run in_repo "$BIN/synapse-query.sh" sources "Java — the application" --count
  [ "$status" -eq 0 ]
  [ "$output" -eq "$(wc -l < "$WORK/lists/01.txt" | tr -d ' ')" ]
  [ "$output" -eq 3 ]

  run in_repo "$BIN/synapse-query.sh" sources "Docs — the documentation" --modules
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs"* ]]

  run in_repo "$BIN/synapse-query.sh" field "OCaml — the library" project
  [ "$status" -eq 0 ]
  [ "$output" = "$(repo_name)" ]
}

@test "a freshly built namespace verifies clean, and detects a real edit" {
  run run_pipeline
  [ "$status" -eq 0 ]

  # Silence means clean: the digests the writer computed must satisfy the
  # verifier's independent recomputation of the same definition.
  run in_repo "$BIN/synapse-query.sh" stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf 'class App { int x; }\n' > "$REPO/src/main/java/com/example/App.java"
  run in_repo "$BIN/synapse-query.sh" stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"Java — the application	content changed"* ]]
  # Only the node covering that file may be flagged.
  [[ "$output" != *"OCaml"* ]]
  [[ "$output" != *"Docs"* ]]
}

@test "a deleted source is reported by name rather than crashing the verifier" {
  run run_pipeline
  [ "$status" -eq 0 ]

  rm "$REPO/lib/core.ml"
  run in_repo "$BIN/synapse-query.sh" stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"OCaml — the library	source files gone: lib/core.ml"* ]]
}

@test "re-running the pipeline is idempotent" {
  run run_pipeline
  [ "$status" -eq 0 ]
  local ns="$VAULT/synapse/$(repo_name)"
  local first; first="$(grep '^sources_digest: ' "$ns/Java — the application.md")"

  run run_pipeline
  [ "$status" -eq 0 ]
  [ "$(grep '^sources_digest: ' "$ns/Java — the application.md")" = "$first" ]

  # Node count must not drift, and the namespace must still verify.
  [ "$(find "$ns" -name '*.md' ! -name 'Index.md' | wc -l | tr -d ' ')" -eq 3 ]
  run in_repo "$BIN/synapse-query.sh" stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
