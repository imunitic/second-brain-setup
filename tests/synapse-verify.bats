#!/usr/bin/env bats
# Tests claude/bin/synapse-verify.sh (Tier 2 batch staleness verification).
# The Obsidian Local REST API is stubbed by tests/fixtures/fake-bin/curl,
# which serves and writes real files under $FAKE_CURL_VAULT_DIR -- so these
# tests exercise the script's actual digest arithmetic against real git
# objects, not a mock of it.
#
# The expected digest is computed independently in python rather than by
# reusing the script's own formula, so a change to either implementation
# fails the test instead of silently agreeing with itself.

load 'test_helper'

VERIFY="$REPO_ROOT/claude/bin/synapse-verify.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
}

teardown() {
  common_teardown
}

run_verify() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    bash "$VERIFY" "$REPO"
}

# sha256 over the LC_ALL=C sorted "path:hash" lines, newline-joined, no
# trailing newline -- computed independently of the script under test.
expected_digest() {
  python3 - "$REPO" "$@" <<'PY'
import hashlib, subprocess, sys
repo, paths = sys.argv[1], sys.argv[2:]
hs = subprocess.run(["git", "-C", repo, "hash-object"] + paths,
                    capture_output=True, text=True).stdout.split()
lines = sorted(f"{p}:{h}" for p, h in zip(paths, hs))
print(hashlib.sha256("\n".join(lines).encode()).hexdigest())
PY
}

# Writes a node covering the given repo-relative paths, with a digest that is
# correct by construction unless $FORCE_DIGEST is set.
write_node() {
  local node="$1"; shift
  local digest="${FORCE_DIGEST:-$(expected_digest "$@")}"
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    echo "---"
    echo "title: \"${node%.md}\""
    echo "node_type: synapse-node"
    echo "project: $(repo_name)"
    echo "sources:"
    local p h
    for p in "$@"; do
      h="$(git -C "$REPO" hash-object "$p")"
      echo "  - path: $p"
      echo "    hash: $h"
    done
    echo "sources_digest: \"$digest\""
    echo "stale: false"
    echo "built_at: \"2026-08-03 16:15\""
    echo "---"
    echo
    echo "# ${node%.md}"
  } > "$VAULT/synapse/$(repo_name)/$node"
}

write_node_index() {
  mkdir -p "$VAULT/synapse/$(repo_name)"
  printf '%s' "$1" > "$VAULT/synapse/$(repo_name)/_index.json"
}

@test "node whose files are unchanged: reports nothing, exit 0" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_verify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "source file changed outside Claude Code: reports the node" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  # The case Tier 1 cannot see: an edit that never went through a hook.
  printf 'let x = 2 (* changed *)\n' > "$REPO/src/foo.ml"

  run run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"Foo Node"* ]]
  [[ "$output" == *"content changed"* ]]
}

@test "recorded source file deleted: reports it by name" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  rm "$REPO/src/foo.ml"

  run run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"source files gone: src/foo.ml"* ]]
}

@test "multi-file node: order in sources does not affect the digest" {
  make_repo
  printf 'let y = 1\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m bar

  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # written in reverse order; the digest sorts, so it must still verify
  write_node "Foo Node.md" "src/foo.ml" "src/bar.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"src/bar.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_verify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "node with a wrong stored digest: reported as changed" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  FORCE_DIGEST="0000000000000000000000000000000000000000000000000000000000000000" \
    write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"content changed"* ]]
}

@test "node built before sources_digest existed: reported, not silently passed" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  # strip the digest, simulating a namespace built under the old format
  grep -v '^sources_digest:' "$VAULT/synapse/$(repo_name)/Foo Node.md" > "$TEST_HOME/tmp" \
    && mv "$TEST_HOME/tmp" "$VAULT/synapse/$(repo_name)/Foo Node.md"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sources_digest"* ]]
}

@test "node in _index.json but missing from the vault: reported" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node_index '{"src/foo.ml":["Ghost Node.md"],"_unassigned":[]}'

  run run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"node file missing"* ]]
}

@test "namespace belongs to a different remote: exits 1, reports nothing" {
  make_repo "ssh://git@example.com/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_verify
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "no namespace for this repo: exits 1, reports nothing" {
  make_repo
  run run_verify
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "not inside a git repo: exits 1" {
  mkdir -p "$TEST_HOME/plain"
  PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    run bash "$VERIFY" "$TEST_HOME/plain"
  [ "$status" -eq 1 ]
}
