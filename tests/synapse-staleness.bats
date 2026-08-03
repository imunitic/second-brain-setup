#!/usr/bin/env bats
# Tests claude/hooks/synapse-staleness.sh (Tier 1 PostToolUse staleness
# flagging). The Obsidian Local REST API is stubbed out by
# tests/fixtures/fake-bin/curl -- see that file for exactly what it
# simulates -- so these tests exercise the hook's own logic (repo/path
# resolution, _index.json lookup, decision to PATCH vs. queue-unassigned)
# without a real Obsidian instance.

load 'test_helper'

HOOK="$REPO_ROOT/claude/hooks/synapse-staleness.sh"

# Writes a Synapse node whose frontmatter contains every shape the old
# `PATCH -H "Target-Type: frontmatter"` call used to mangle: a title long
# enough to be line-folded, quoted values, and an all-digit `hash` that
# YAML happily coerces to a float.
write_synapse_node() {
  local project="$1" node="$2" stale="${3:-false}"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/$node" <<EOF
---
title: "A deliberately long node title that a re-serialising writer would fold across two lines"
node_type: synapse-node
project: $project
sources:
  - path: src/foo.ml
    hash: 1111111111111111111111111111111111111111
sources_digest: "2222222222222222222222222222222222222222222222222222222222222222"
stale: $stale
built_at: "2026-08-03 16:15"
---

# A node

Body text, including a decoy: stale: false
EOF
}

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  CURL_CAPTURE="$TEST_HOME/curl-capture"
  : > "$CURL_LOG"
  mkdir -p "$CURL_CAPTURE"
}

teardown() {
  common_teardown
}

# Runs the hook against $1 (the edited file path) with the fake curl on
# PATH and the fake API's canned _index.json response set to $2 (a file
# path, or empty for "no namespace exists / 404").
run_staleness_hook() {
  local file="$1" index_body="${2:-}"
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_CAPTURE_DIR="$CURL_CAPTURE" \
    FAKE_CURL_INDEX_BODY="$index_body" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c "printf '%s' \"\$1\" | jq -Rn '{tool_input:{file_path: input}}' | bash \"\$0\"" "$HOOK" "$file"
}

@test "file mapped to a node: rewrites that node's stale line, never PATCHes frontmatter" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{
  "src/foo.ml": ["Foo Node.md"],
  "_unassigned": []
}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]

  grep -q "synapse/$(repo_name)/Foo Node.md" "$CURL_CAPTURE/node-puts.log"
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Foo Node.md"
  # The frontmatter-patch call is the bug being fixed -- it must never reappear.
  [ ! -f "$CURL_CAPTURE/patches.log" ]
  ! grep -q "Target-Type: frontmatter" "$CURL_LOG"
  [ ! -f "$CURL_CAPTURE/index-put.json" ]
}

@test "file mapped to two nodes: flags both" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false
  write_synapse_node "$(repo_name)" "Bar Node.md" false

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{
  "src/foo.ml": ["Foo Node.md", "Bar Node.md"],
  "_unassigned": []
}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]

  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Foo Node.md"
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Bar Node.md"
  [ "$(wc -l < "$CURL_CAPTURE/node-puts.log" | tr -d ' ')" = "2" ]
}

@test "new file not in any node's sources: queued into _unassigned via PUT, no PATCH" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{
  "src/other.ml": ["Other Node.md"],
  "_unassigned": []
}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]

  [ -f "$CURL_CAPTURE/index-put.json" ]
  run jq -e '.["_unassigned"] | index("src/foo.ml")' "$CURL_CAPTURE/index-put.json"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/patches.log" ]
}

@test "no Synapse namespace for this repo (real 404 JSON body): no-op, no PUT or PATCH" {
  # Regression test: the real Local REST API returns a 404 with a JSON body
  # (`{"message":"Not Found","errorCode":40400}`), which is itself valid
  # JSON -- a hook that only checked "is the response valid JSON" (rather
  # than the actual HTTP status) would treat this as an existing index and
  # PUT a stray `_unassigned` field onto it. Found in the wild: exactly this
  # happened to two repos edited before ever running /synapse-init.
  make_repo
  # The namespace Index.md must exist with a matching remote, or the hook's
  # remote guard exits before the GET and this test would pass vacuously --
  # covering the guard rather than the 404 handling it is named for.
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # No --2nd-arg body -- fake curl's GET returns the real API's 404 JSON
  # body + status 404 for _index.json.
  run run_staleness_hook "$REPO/src/foo.ml" ""
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/index-put.json" ]
  [ ! -f "$CURL_CAPTURE/patches.log" ]
}

@test "no OBSIDIAN_VAULT_DIR configured: exits before any curl call at all" {
  cat > "$HOME/.claude/second-brain.conf" <<'EOF'
EOF
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{"src/foo.ml": ["Foo Node.md"], "_unassigned": []}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "edited file outside any git repo: no-op" {
  local outside="$TEST_HOME/not-a-repo"
  mkdir -p "$outside"
  printf 'stray\n' > "$outside/stray.txt"

  run run_staleness_hook "$outside/stray.txt" ""
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "node title with special characters is percent-encoded correctly in the request URL" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "World — entity_component_resource core.md" false

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{
  "src/foo.ml": ["World — entity_component_resource core.md"],
  "_unassigned": []
}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  grep -q "World%20%E2%80%94%20entity_component_resource%20core.md" "$CURL_LOG"
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/World — entity_component_resource core.md"
}

@test "flagging a node leaves every byte outside the stale line untouched" {
  # Regression test for the frontmatter-corruption bug. The old
  # `PATCH -H "Target-Type: frontmatter" -H "Target: stale"` call was not
  # field-local: it re-serialised the whole YAML block, stripping quotes from
  # every value, folding long `title:` lines in two, and YAML-coercing an
  # all-digit `hash` into scientific notation (verified 2026-08-03:
  # 1111111111111111111111111111111111111111 -> 1.1111111111111112e+39).
  # A corrupted hash makes sources_digest disagree with its own sources
  # permanently, so verification would report the node stale forever.
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  local node="$VAULT/synapse/$(repo_name)/Foo Node.md"
  cp "$node" "$TEST_HOME/before.md"

  cat > "$TEST_HOME/index-body.json" <<'JSON'
{"src/foo.ml": ["Foo Node.md"], "_unassigned": []}
JSON

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]

  # Exactly one line differs, and it is the stale line.
  run diff "$TEST_HOME/before.md" "$node"
  [ "$status" -eq 1 ]
  [ "$(diff "$TEST_HOME/before.md" "$node" | grep -c '^[<>]')" = "2" ]
  diff "$TEST_HOME/before.md" "$node" | grep -q '^< stale: false$'
  diff "$TEST_HOME/before.md" "$node" | grep -q '^> stale: true$'

  # The specific values the old call destroyed.
  grep -q 'hash: 1111111111111111111111111111111111111111' "$node"
  grep -q '^title: "A deliberately long node title' "$node"
  grep -q '^built_at: "2026-08-03 16:15"$' "$node"
  grep -q 'decoy: stale: false' "$node"
}

@test "node already stale: no write at all" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" true

  cat > "$TEST_HOME/index-body.json" <<'JSON'
{"src/foo.ml": ["Foo Node.md"], "_unassigned": []}
JSON

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  # Already true -> the hook must skip the PUT rather than churn the file.
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
}

@test "node listed in _index.json but missing from the vault: no-op, no crash" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # deliberately no write_synapse_node -- fake curl's GET -o exits 22

  cat > "$TEST_HOME/index-body.json" <<'JSON'
{"src/foo.ml": ["Ghost Node.md"], "_unassigned": []}
JSON

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
}

@test "namespace belongs to a different remote: no write, and no HTTP at all" {
  # A namespace is keyed by directory basename, so two unrelated repos sharing
  # one would write into each other's graph. This is the write-side half of the
  # check the SessionStart hook and synapse-query.sh already make.
  make_repo "ssh://git@example.com/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  cat > "$TEST_HOME/index-body.json" <<'JSON'
{"src/foo.ml": ["Foo Node.md"], "_unassigned": []}
JSON

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
  [ ! -f "$CURL_CAPTURE/index-put.json" ]
  # The guard is ahead of any HTTP, so nothing should have been dialed at all.
  [ ! -s "$CURL_LOG" ]
  grep -q '^stale: false$' "$VAULT/synapse/$(repo_name)/Foo Node.md"
}

@test "namespace Index.md with no remote line: treated as a mismatch, not a match on empty" {
  make_repo "ssh://git@example.com/mine.git"
  mkdir -p "$VAULT/synapse/$(repo_name)"
  cat > "$VAULT/synapse/$(repo_name)/Index.md" <<'EOF2'
---
title: "no remote here"
---
# index
EOF2
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  cat > "$TEST_HOME/index-body.json" <<'JSON'
{"src/foo.ml": ["Foo Node.md"], "_unassigned": []}
JSON

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
  [ ! -s "$CURL_LOG" ]
}

@test "repo with no remote at all: falls back to the repo root and still matches" {
  # A repo without an `origin` must compare equal against its own namespace --
  # this is why the hook has to reuse the exact origin -> first-remote ->
  # repo-root chain the other components use.
  make_repo   # no remote argument
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  cat > "$TEST_HOME/index-body.json" <<'JSON'
{"src/foo.ml": ["Foo Node.md"], "_unassigned": []}
JSON

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Foo Node.md"
}
