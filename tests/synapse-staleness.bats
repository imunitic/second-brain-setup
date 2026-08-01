#!/usr/bin/env bats
# Tests claude/hooks/synapse-staleness.sh (Tier 1 PostToolUse staleness
# flagging). The Obsidian Local REST API is stubbed out by
# tests/fixtures/fake-bin/curl -- see that file for exactly what it
# simulates -- so these tests exercise the hook's own logic (repo/path
# resolution, _index.json lookup, decision to PATCH vs. queue-unassigned)
# without a real Obsidian instance.

load 'test_helper'

HOOK="$REPO_ROOT/claude/hooks/synapse-staleness.sh"

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
    bash -c "printf '%s' \"\$1\" | jq -Rn '{tool_input:{file_path: input}}' | bash \"\$0\"" "$HOOK" "$file"
}

@test "file mapped to a node: PATCHes that node's stale field, no PUT" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{
  "src/foo.ml": ["Foo Node.md"],
  "_unassigned": []
}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]

  [ -f "$CURL_CAPTURE/patches.log" ]
  grep -q "synapse/$(repo_name)/Foo%20Node.md" "$CURL_CAPTURE/patches.log"
  grep -q -- "-X PATCH" "$CURL_LOG"
  grep -q "Target: stale" "$CURL_LOG"
  [ ! -f "$CURL_CAPTURE/index-put.json" ]
}

@test "file mapped to two nodes: PATCHes both" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{
  "src/foo.ml": ["Foo Node.md", "Bar Node.md"],
  "_unassigned": []
}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]

  grep -q "synapse/$(repo_name)/Foo%20Node.md" "$CURL_CAPTURE/patches.log"
  grep -q "synapse/$(repo_name)/Bar%20Node.md" "$CURL_CAPTURE/patches.log"
  [ "$(wc -l < "$CURL_CAPTURE/patches.log" | tr -d ' ')" = "2" ]
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

@test "no Synapse namespace for this repo (404 / empty response): no-op, no PUT or PATCH" {
  make_repo
  # No write_synapse_index call, no --2nd-arg body -- fake curl's GET
  # returns nothing, simulating a 404 from the real REST API.
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

@test "node title with special characters is percent-encoded correctly in the PATCH URL" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  cat > "$TEST_HOME/index-body.json" <<'EOF'
{
  "src/foo.ml": ["World — entity_component_resource core.md"],
  "_unassigned": []
}
EOF

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-body.json"
  [ "$status" -eq 0 ]
  grep -q "World%20%E2%80%94%20entity_component_resource%20core.md" "$CURL_CAPTURE/patches.log"
}
