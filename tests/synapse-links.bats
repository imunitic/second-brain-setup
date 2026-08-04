#!/usr/bin/env bats
# Tests `synapse-query.sh links` -- relations between nodes, derived from disk on
# demand rather than cached. There is no _relations.json on purpose: a few dozen
# nodes is kilobytes of edges, so a cached projection would be a fourth artifact
# to rebuild after every write, misleading silently once stale, in exchange for
# nothing.
#
# The relation type lives in prose (`- depends_on [[X]]`), which Obsidian's link
# graph cannot see, so these tests are also the contract on that line's shape: if
# the writer's Links format changes, the parser must change with it.

load 'test_helper'

QUERY="$REPO_ROOT/claude/bin/synapse-query.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"; : > "$CURL_LOG"
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
}
teardown() { common_teardown; }

ns() { echo "$VAULT/synapse/$(repo_name)"; }

# A node carrying only a Links section -- enough for the parser, and it keeps the
# fixtures readable.
node() { # node <title> <links-block...>
  local title="$1"; shift
  mkdir -p "$(ns)"
  { printf -- '---\ntitle: "%s"\nsummary: "S."\n---\n\n# %s\n' "$title" "$title"
    printf '<!-- synapse:generated:start -->\n\n## Summary\nProse.\n\n## Links\n'
    for l in "$@"; do printf -- '- %s\n' "$l"; done
    printf '\n## Sources\n- `src` (1)\n<!-- synapse:generated:end -->\n\n## Notes\n'
  } > "$(ns)/$title.md"
}

run_q() {
  PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$QUERY" "$@"
}

@test "links: outbound relations come back with their type" {
  node "Alpha" "depends_on [[Beta]]" "uses [[Gamma]]"
  node "Beta"; node "Gamma"

  run run_q links "Alpha"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [[ "$output" == *"depends_on	Beta"* ]]
  [[ "$output" == *"uses	Gamma"* ]]
}

@test "links: --inbound distinguishes relations, which the link graph cannot" {
  node "Alpha" "depends_on [[Target]]"
  node "Beta"  "uses [[Target]]"
  node "Gamma" "depends_on [[Target]]"
  node "Target"

  run run_q links "Target" --inbound
  [ "$status" -eq 0 ]
  [[ "$output" == *"depends_on	Alpha"* ]]
  [[ "$output" == *"depends_on	Gamma"* ]]
  [[ "$output" == *"uses	Beta"* ]]
  # the whole point: Beta must not appear as a depends_on
  [[ "$output" != *"depends_on	Beta"* ]]
}

@test "links: --closure reports every reachable node with its shortest depth" {
  node "A" "uses [[B]]"
  node "B" "uses [[C]]"
  node "C" "uses [[D]]"
  node "D"

  run run_q links "A" --closure
  [ "$status" -eq 0 ]
  [[ "$output" == *"1	B"* ]]
  [[ "$output" == *"2	C"* ]]
  [[ "$output" == *"3	D"* ]]
  # the start node is not its own descendant
  [[ "$output" != *"	A"* ]]
}

@test "links: --closure prefers the shorter path when two exist" {
  node "A" "uses [[B]]" "uses [[C]]"
  node "B" "uses [[D]]"
  node "C"
  node "D"

  run run_q links "A" --closure
  # D is reachable at depth 2 via B; breadth-first must not report it deeper
  [[ "$output" == *"2	D"* ]]
}

@test "links: --closure terminates on a cycle instead of looping" {
  node "A" "uses [[B]]"
  node "B" "uses [[C]]"
  node "C" "uses [[A]]"

  run run_q links "A" --closure
  [ "$status" -eq 0 ]
  [[ "$output" == *"1	B"* ]]
  [[ "$output" == *"2	C"* ]]
  # A is reachable from itself through the cycle, but is already seen, so the walk
  # stops rather than revisiting it
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "links: --check names a target that resolves to no node" {
  node "Alpha" "depends_on [[Beta]]" "uses [[Ghost]]"
  node "Beta"

  run run_q links --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alpha	uses -> Ghost (no such node)"* ]]
  # a broken wikilink is a valid link to a not-yet-existing note, so Obsidian
  # renders it silently -- this is the only thing that reports it
  [[ "$output" != *"Beta"* ]]
}

@test "links: --check is silent when every target resolves" {
  node "Alpha" "depends_on [[Beta]]"
  node "Beta" "part_of [[Alpha]]"

  run run_q links --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "links: a node with no Links section returns nothing, exit 0" {
  node "Lonely"
  run run_q links "Lonely"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "links: an unknown node exits 1 rather than reporting no relations" {
  node "Alpha" "uses [[Beta]]"
  node "Beta"
  run run_q links "Nope"
  [ "$status" -eq 1 ]
}

@test "links: usage errors exit 2" {
  node "Alpha"
  run run_q links
  [ "$status" -eq 2 ]
  run run_q links "Alpha" --bogus
  [ "$status" -eq 2 ]
  run run_q links --check extra
  [ "$status" -eq 2 ]
}
