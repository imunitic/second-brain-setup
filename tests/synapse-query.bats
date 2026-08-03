#!/usr/bin/env bats
# Tests claude/bin/synapse-query.sh. The `stale` subcommand is the Tier 2 batch
# staleness verification that used to live in synapse-verify.sh.
# The Obsidian Local REST API is stubbed by tests/fixtures/fake-bin/curl,
# which serves and writes real files under $FAKE_CURL_VAULT_DIR -- so these
# tests exercise the script's actual digest arithmetic against real git
# objects, not a mock of it.
#
# The expected digest is computed independently in python rather than by
# reusing the script's own formula, so a change to either implementation
# fails the test instead of silently agreeing with itself.

load 'test_helper'

QUERY="$REPO_ROOT/claude/bin/synapse-query.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
}

teardown() {
  common_teardown
}

# The script resolves the repo from $PWD, so run it from inside $REPO.
run_query() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$QUERY" "$@"
}

run_stale() { run_query stale; }

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

@test "stale: node whose files are unchanged: reports nothing, exit 0" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stale: source file changed outside Claude Code: reports the node" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  # The case Tier 1 cannot see: an edit that never went through a hook.
  printf 'let x = 2 (* changed *)\n' > "$REPO/src/foo.ml"

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"Foo Node"* ]]
  [[ "$output" == *"content changed"* ]]
}

@test "stale: recorded source file deleted: reports it by name" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  rm "$REPO/src/foo.ml"

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"source files gone: src/foo.ml"* ]]
}

@test "stale: multi-file node: order in sources does not affect the digest" {
  make_repo
  printf 'let y = 1\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m bar

  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # written in reverse order; the digest sorts, so it must still verify
  write_node "Foo Node.md" "src/foo.ml" "src/bar.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"src/bar.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stale: node with a wrong stored digest: reported as changed" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  FORCE_DIGEST="0000000000000000000000000000000000000000000000000000000000000000" \
    write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"content changed"* ]]
}

@test "stale: node built before sources_digest existed: reported, not silently passed" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  # strip the digest, simulating a namespace built under the old format
  grep -v '^sources_digest:' "$VAULT/synapse/$(repo_name)/Foo Node.md" > "$TEST_HOME/tmp" \
    && mv "$TEST_HOME/tmp" "$VAULT/synapse/$(repo_name)/Foo Node.md"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sources_digest"* ]]
}

@test "stale: node in _index.json but missing from the vault: reported" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node_index '{"src/foo.ml":["Ghost Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"node file missing"* ]]
}

@test "stale: namespace belongs to a different remote: exits 1, reports nothing" {
  make_repo "ssh://git@example.com/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "stale: no namespace for this repo: exits 1, reports nothing" {
  make_repo
  run run_stale
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "stale: not inside a git repo: exits 1" {
  mkdir -p "$TEST_HOME/plain"
  run bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_CURL_LOG="$3" FAKE_CURL_VAULT_DIR="$4" bash "$5" stale' \
    _ "$TEST_HOME/plain" "$FAKE_BIN" "$CURL_LOG" "$VAULT" "$QUERY"
  [ "$status" -eq 1 ]
}

# --- body / sources / field ------------------------------------------------
# The point of these subcommands is that they read the expensive parts
# internally and print only a projection, so the assertions are mostly about
# what is *absent* from the output.

# A node with a generated fence, real hashes, and Notes content that must never
# leak into `body`.
write_fenced_node() {
  local node="$1"; shift
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    echo "---"
    echo "title: \"${node%.md}\""
    echo "node_type: synapse-node"
    echo "project: $(repo_name)"
    echo "sources:"
    local p
    for p in "$@"; do
      echo "  - path: $p"
      echo "    hash: $(git -C "$REPO" hash-object "$p")"
    done
    echo "sources_digest: \"$(expected_digest "$@")\""
    echo "stale: false"
    echo "built_at: \"2026-08-03 16:15\""
    echo "---"
    echo
    echo "# ${node%.md}"
    echo "<!-- synapse:generated:start -->"
    echo
    echo "## Summary"
    echo "Prose that should be printed."
    echo
    echo "## Sources"
    echo "- \`src\` (${#@})"
    echo "<!-- synapse:generated:end -->"
    echo
    echo "## Notes"
    echo "HUMAN NOTES must never appear in body output."
  } > "$VAULT/synapse/$(repo_name)/$node"
}

@test "body: prints the fenced prose only, excluding frontmatter and Notes" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query body "Foo Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prose that should be printed."* ]]
  [[ "$output" != *"path:"* ]]
  [[ "$output" != *"HUMAN NOTES"* ]]
  [[ "$output" != *"sources_digest"* ]]
  [[ "$output" != *"synapse:generated"* ]]
}

@test "body: accepts the node name with or without .md" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query body "Foo Node.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prose that should be printed."* ]]
}

@test "body: unfenced node falls back to post-frontmatter and warns on stderr" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Old Node.md" "src/foo.ml"   # written without a fence

  run run_query body "Old Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no generated fence"* ]]
  [[ "$output" != *"path:"* ]]
}

@test "body: unknown node exits 1" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_query body "Nope"
  [ "$status" -eq 1 ]
}

@test "sources: --count matches the real number of paths" {
  make_repo
  printf 'let y = 1\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m bar
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "src/bar.ml"

  run run_query sources "Foo Node" --count
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "sources: bare form lists every path, --filter narrows it" {
  make_repo
  printf 'let y = 1\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m bar
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "src/bar.ml"

  run run_query sources "Foo Node"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]

  run run_query sources "Foo Node" --filter bar
  [ "$output" = "src/bar.ml" ]
}

@test "sources: --modules groups by module root with counts" {
  make_repo
  mkdir -p "$REPO/other/src/main"
  printf 'x\n' > "$REPO/other/src/main/A.java"
  git -C "$REPO" add other/src/main/A.java
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m other
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "other/src/main/A.java"

  run run_query sources "Foo Node" --modules
  [ "$status" -eq 0 ]
  # `other/src/main/A.java` groups as `other`; `src/foo.ml` has src first so it
  # is the repo root's own src -- grouped as "src" per the module_of rule.
  [[ "$output" == *"other"$'\t'"1"* ]]
}

@test "field: returns unquoted scalars, empty for an absent key" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query field "Foo Node" stale
  [ "$output" = "false" ]

  run run_query field "Foo Node" built_at
  [ "$output" = "2026-08-03 16:15" ]     # quotes stripped

  run run_query field "Foo Node" nonexistent_key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "field: refuses 'sources' with exit 2 and points at the right subcommand" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query field "Foo Node" sources
  [ "$status" -eq 2 ]
  [[ "$output" == *"use: synapse-query.sh sources"* ]]
}

@test "unknown subcommand and no subcommand both exit 2" {
  make_repo
  run run_query bogus
  [ "$status" -eq 2 ]
  run run_query
  [ "$status" -eq 2 ]
}
