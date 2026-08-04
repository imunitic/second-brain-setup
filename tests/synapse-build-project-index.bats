#!/usr/bin/env bats
# Tests claude/bin/synapse-build-project-index.sh -- the per-project Index.md.
#
# Three properties carry real consequences. The `remote` field must resolve exactly
# as the SessionStart hook, synapse-staleness.sh and synapse-query.sh do, or the
# namespace silently compares unequal against its own repo and nothing is ever
# injected. Each bullet must link by *filename*, since that is what Obsidian
# resolves -- linking by title breaks the moment a title needs sanitizing. And each
# summary is read back off the node itself, so the index cannot describe a node as
# it used to be.

load 'test_helper'

BUILD_PINDEX="$REPO_ROOT/claude/bin/synapse-build-project-index.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK/lists"
}

teardown() {
  common_teardown
}

run_pindex() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_PUT_STATUS="${PUT_STATUS:-200}" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$BUILD_PINDEX" "$@"
}

stage_list() {
  local nn="$1" title="$2"; shift 2
  printf '%s\n' "$title" > "$WORK/lists/$nn.title"
  printf '%s\n' "$@" > "$WORK/lists/$nn.txt"
}

# Writes the node file the builder reads its summary back from, as
# synapse-write-node.sh would: filename sanitized, and the summary escaped for a
# double-quoted YAML scalar (backslash first, then quote) so callers can pass the
# human-readable string.
stage_node() {
  local title="$1" raw="$2"
  local summary="${raw//\\/\\\\}"
  summary="${summary//\"/\\\"}"
  local link; link="$(printf '%s' "$title" | tr '/:*?"<>|' '_')"
  mkdir -p "$VAULT/synapse/$(repo_name)"
  cat > "$VAULT/synapse/$(repo_name)/$link.md" <<EOF
---
title: "$title"
summary: "$summary"
node_type: synapse-node
project: $(repo_name)
sources:
  - path: x
    hash: y
sources_digest: deadbeef
stale: false
built_at: "2026-01-01 00:00"
---

# $title
<!-- synapse:generated:start -->
body
<!-- synapse:generated:end -->

## Notes
EOF
}

index_file() { echo "$VAULT/synapse/$(repo_name)/Index.md"; }

@test "writes the frontmatter the SessionStart hook expects" {
  make_repo "ssh://git@example.com/x/proj.git"
  stage_list 01 "Mod A" mod-a/a.txt mod-a/b.txt
  stage_node "Mod A" "The first module."

  run run_pindex
  [ "$status" -eq 0 ]

  local f; f="$(index_file)"
  grep -q "^title: \"$(repo_name) — Synapse index\"\$" "$f"
  grep -q '^node_type: synapse-index$' "$f"
  grep -q "^project: $(repo_name)\$" "$f"
  grep -q '^remote: "ssh://git@example.com/x/proj.git"$' "$f"
  grep -qE '^built_at: "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}"$' "$f"
}

@test "remote falls back to the first configured remote when there is no origin" {
  make_repo
  git -C "$REPO" remote add upstream "ssh://git@example.com/x/up.git"
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "Only node."

  run run_pindex
  [ "$status" -eq 0 ]
  grep -q '^remote: "ssh://git@example.com/x/up.git"$' "$(index_file)"
}

@test "remote falls back to the git-resolved repo root when there is no remote at all" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "Only node."

  run run_pindex
  [ "$status" -eq 0 ]
  # The git-resolved path, not the raw $REPO variable: rev-parse resolves symlinks
  # (macOS /tmp -> /private/tmp) and that is what the other components compare.
  grep -q "^remote: \"$(git -C "$REPO" rev-parse --show-toplevel)\"\$" "$(index_file)"
}

@test "each bullet carries the node's own summary and its file count" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt mod-a/b.txt mod-a/c.txt
  stage_list 02 "Docs" docs/d.md
  stage_node "Mod A" "The first module."
  stage_node "Docs" "The documentation."

  run run_pindex
  [ "$status" -eq 0 ]
  grep -q '^- \[\[Mod A\]\] — The first module\. (3 files)$' "$(index_file)"
  grep -q '^- \[\[Docs\]\] — The documentation\. (1 files)$' "$(index_file)"
}

@test "editing a node's summary changes the index, with no second copy to update" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "First wording."
  run run_pindex
  [ "$status" -eq 0 ]
  grep -q 'First wording\.' "$(index_file)"

  # The whole point of keeping the summary on the node: rewriting it cannot leave
  # the index describing the node as it used to be.
  stage_node "Mod A" "Second wording."
  run run_pindex
  [ "$status" -eq 0 ]
  grep -q 'Second wording\.' "$(index_file)"
  ! grep -q 'First wording\.' "$(index_file)"
}

@test "quotes and backslashes in a summary survive the round trip" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" 'Handles "quoted" input and a C:\path.'

  run run_pindex
  [ "$status" -eq 0 ]
  grep -qF 'Handles "quoted" input and a C:\path.' "$(index_file)"
}

@test "bullets link by filename, so a sanitized title still resolves" {
  make_repo
  stage_list 01 "Bad — import/export" mod-a/a.txt
  stage_node "Bad — import/export" "Small modules."

  run run_pindex
  [ "$status" -eq 0 ]
  # The wikilink must match the file the writer produced, not the raw title.
  grep -q '^- \[\[Bad — import_export\]\] — Small modules\. (1 files)$' "$(index_file)"
  ! grep -q '\[\[Bad — import/export\]\]' "$(index_file)"
}

@test "bullets are sorted by title, not by list number" {
  make_repo
  stage_list 01 "Zeta module" z/z.txt
  stage_list 02 "Alpha module" a/a.txt
  stage_node "Zeta module" "Last alphabetically."
  stage_node "Alpha module" "First alphabetically."

  run run_pindex
  [ "$status" -eq 0 ]
  # An index of dozens of entries is scanned for a name, so alphabetical is the
  # only order a reader can predict.
  local first second
  first="$(grep -n '\[\[Alpha module\]\]' "$(index_file)" | cut -d: -f1)"
  second="$(grep -n '\[\[Zeta module\]\]' "$(index_file)" | cut -d: -f1)"
  [ "$first" -lt "$second" ]
}

@test "the index carries no repo-specific prose at all" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "Only node."

  run run_pindex
  [ "$status" -eq 0 ]

  # A whitelist, not a blacklist of suspicious words: every prose line must be one
  # of the two generic sentences, so ANY repo-specific text fails regardless of how
  # it is worded. A sentence describing one codebase's conventions is confident
  # nonsense in every other codebase. A convention worth explaining is a concept,
  # so it belongs in a node -- searchable, staleness-tracked -- not in the index.
  run bash -c "awk 'NR==1 && \$0 == \"---\" { fm = 1; next } fm && \$0 == \"---\" { fm = 0; body = 1; next } body' '$(index_file)' \
      | grep -v '^- \[\[' | grep -v '^# ' | sed '/^\$/d' \
      | grep -vcE '(tracked files, [0-9]+ nodes\.|^Reading a node:)' || true"
  [ "$output" -eq 0 ]

  # ...and the generic reading guidance must still be present.
  grep -q 'synapse-query.sh body' "$(index_file)"
}

@test "the file count comes from all.txt when present" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "Only node."
  printf 'a\nb\nc\nd\n' > "$WORK/all.txt"

  run run_pindex
  [ "$status" -eq 0 ]
  grep -q '^4 tracked files, 1 nodes\.' "$(index_file)"
  [[ "$output" == *"4 tracked files"* ]]
}

@test "a node that is not in the vault yet exits 1 rather than emitting a dead link" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_list 02 "Never written" x/x.txt
  stage_node "Mod A" "Only node."

  run run_pindex
  [ "$status" -eq 1 ]
  [[ "$output" == *"node not in the vault: Never written.md"* ]]
  [[ "$output" == *"write them first"* ]]
}

@test "a node with no summary field exits 1" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  mkdir -p "$VAULT/synapse/$(repo_name)"
  printf -- '---\ntitle: "Mod A"\nnode_type: synapse-node\n---\n\n# Mod A\n' \
    > "$VAULT/synapse/$(repo_name)/Mod A.md"

  run run_pindex
  [ "$status" -eq 1 ]
  [[ "$output" == *"no summary field on Mod A.md"* ]]
}

@test "missing lists and a failed PUT each exit 1" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "Only node."

  PUT_STATUS=503 run run_pindex
  [ "$status" -eq 1 ]
  [[ "$output" == *"PUT failed (503)"* ]]

  rm -rf "$WORK/lists"
  run run_pindex
  [ "$status" -eq 1 ]
  [[ "$output" == *"no lists/"* ]]
}
