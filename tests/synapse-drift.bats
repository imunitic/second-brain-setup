#!/usr/bin/env bats
# Tests `synapse-query.sh drift` -- what changed since each node's recorded commit.
#
# It complements `stale` rather than replacing it: `stale` re-hashes what a node
# already claims, so it is blind to *added* files by construction, and it reports a
# rename as a deletion. `drift` diffs `commit..HEAD`, so additions, deletions and
# renames are all visible, and the cost is one `git diff` per distinct baseline.
#
# Nodes are written by hand here rather than through synapse-write-node.sh, because
# these tests need to control `commit` exactly -- including the cases where it is
# absent or points at a commit that is not in this history.

load 'test_helper'

QUERY="$REPO_ROOT/claude/bin/synapse-query.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
}

teardown() {
  common_teardown
}

run_drift() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$QUERY" drift "$@"
}

# A repo with two independent areas, so a change in one can be asserted not to
# implicate the other.
make_two_area_repo() {
  make_repo
  mkdir -p "$REPO/mod-a" "$REPO/docs"
  printf 'class A {}\n' > "$REPO/mod-a/a.java"
  printf 'class B {}\n' > "$REPO/mod-a/b.java"
  printf '# guide\n' > "$REPO/docs/guide.md"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m two-areas
}

git_head() { git -C "$REPO" rev-parse HEAD; }

commit_all() { # commit_all <message>
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "$1"
}

# Writes a node with an explicit baseline commit and source list. Pass "" as the
# commit to omit the field entirely.
stage_node() { # stage_node <title> <commit> <path>...
  local title="$1" commit="$2"; shift 2
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    echo '---'
    echo "title: \"$title\""
    echo 'summary: "One line."'
    echo 'node_type: synapse-node'
    echo "project: $(repo_name)"
    echo 'sources:'
    local p
    for p in "$@"; do
      echo "  - path: $p"
      echo "    hash: $(git -C "$REPO" hash-object "$p" 2>/dev/null || echo deadbeef)"
    done
    echo 'sources_digest: notchecked'
    echo 'stale: false'
    echo 'built_at: "2026-01-01 00:00"'
    [ -n "$commit" ] && echo "commit: $commit"
    echo '---'
    echo
    echo "# $title"
    echo '<!-- synapse:generated:start -->'
    echo 'body'
    echo '<!-- synapse:generated:end -->'
    echo
    echo '## Notes'
  } > "$VAULT/synapse/$(repo_name)/$title.md"
}

# _index.json mapping each given path to one node, as synapse-build-index.sh would.
stage_index() { # stage_index <node.md> <path>...
  local node="$1"; shift
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    printf '{'
    local first=1 p
    for p in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      printf '"%s":["%s"]' "$p" "$node"
      first=0
    done
    printf ',"_unassigned":[]}'
  } > "$VAULT/synapse/$(repo_name)/_index.json"
}

@test "a namespace built at HEAD reports nothing" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "$(git_head)" mod-a/a.java mod-a/b.java
  stage_index "Mod A.md" mod-a/a.java mod-a/b.java

  run run_drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a modified file is reported against its own node only" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  local base; base="$(git_head)"
  stage_node "Mod A" "$base" mod-a/a.java mod-a/b.java
  stage_node "Docs" "$base" docs/guide.md
  stage_index "Mod A.md" mod-a/a.java mod-a/b.java

  printf 'class A { int x; }\n' > "$REPO/mod-a/a.java"
  commit_all edit

  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mod A	content changed in 1 of its files"* ]]
  [[ "$output" != *"Docs	content changed"* ]]
  [[ "$output" == *"(repo)	1 commits since baseline"* ]]
}

@test "a deleted file is reported as gone" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "$(git_head)" mod-a/a.java mod-a/b.java
  stage_index "Mod A.md" mod-a/a.java mod-a/b.java

  git -C "$REPO" rm -q mod-a/b.java
  commit_all delete

  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mod A	1 of its files are gone"* ]]
}

@test "a rename is reported as reseatable rather than as a deletion" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "$(git_head)" mod-a/a.java mod-a/b.java
  stage_index "Mod A.md" mod-a/a.java mod-a/b.java

  git -C "$REPO" mv mod-a/b.java mod-a/renamed.java
  commit_all rename

  run run_drift
  [ "$status" -eq 0 ]
  # The distinction that matters: the concept is unchanged, only the path moved, so
  # the node can be rewritten from its own prose with an updated path list. `stale`
  # can only ever call this "source files gone".
  [[ "$output" == *"reseat sources, prose may still hold"* ]]
  [[ "$output" != *"are gone"* ]]
}

@test "added paths that an existing manifest pattern already covers are counted, not listed" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "$(git_head)" mod-a/a.java mod-a/b.java
  stage_index "Mod A.md" mod-a/a.java mod-a/b.java
  printf 'Mod A\t^mod-a/\t\n' > "$WORK/manifest.tsv"

  printf 'class C {}\n' > "$REPO/mod-a/c.java"
  printf 'class D {}\n' > "$REPO/mod-a/d.java"
  commit_all adds

  run run_drift
  [ "$status" -eq 0 ]
  # Ordinary development needs no judgment: the clustering patterns claim these on
  # the next build-lists run.
  [[ "$output" == *"2 new paths already match a manifest pattern"* ]]
  [[ "$output" == *"synapse-build-lists.sh"* ]]
  [[ "$output" != *"match no manifest pattern"* ]]
}

@test "an added path matching no manifest pattern is listed for a decision" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "$(git_head)" mod-a/a.java
  stage_index "Mod A.md" mod-a/a.java
  printf 'Mod A\t^mod-a/\t\n' > "$WORK/manifest.tsv"

  mkdir -p "$REPO/brand-new-subsystem"
  printf 'new\n' > "$REPO/brand-new-subsystem/thing.java"
  commit_all newsubsystem

  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 new paths match no manifest pattern"* ]]
  [[ "$output" == *"brand-new-subsystem/thing.java"* ]]
}

@test "without a manifest, unclaimed additions are still reported" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "$(git_head)" mod-a/a.java
  stage_index "Mod A.md" mod-a/a.java
  [ ! -f "$WORK/manifest.tsv" ]

  printf 'class C {}\n' > "$REPO/mod-a/c.java"
  commit_all add

  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"claimed by no node, and no manifest to classify them against"* ]]
}

@test "a node with no commit field says so instead of guessing a baseline" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "" mod-a/a.java
  stage_index "Mod A.md" mod-a/a.java

  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mod A	no commit recorded"* ]]
  [[ "$output" == *'verify with `stale`'* ]]
}

@test "a baseline that is not in local history falls back to stale rather than diffing" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # A plausible but absent sha: force-push, a rebase that dropped it, or a shallow
  # clone. Diffing against it would either fail or, worse, appear to work.
  stage_node "Mod A" "0123456789abcdef0123456789abcdef01234567" mod-a/a.java
  stage_index "Mod A.md" mod-a/a.java

  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline 0123456789ab not in local history"* ]]
  [[ "$output" == *'verify with `stale`'* ]]
}

@test "a node listed in the index but absent from the vault is reported" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_index "Ghost.md" mod-a/a.java

  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ghost	node file missing from the vault"* ]]
}

@test "being behind upstream is context, printed only alongside a finding" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  local base; base="$(git_head)"
  stage_node "Mod A" "$base" mod-a/a.java
  stage_index "Mod A.md" mod-a/a.java

  # A local branch serves as an upstream, keeping the test free of a real remote.
  local branch; branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  git -C "$REPO" branch -q up
  git -C "$REPO" checkout -q up
  printf 'ahead\n' > "$REPO/mod-a/ahead.java"
  commit_all ahead
  git -C "$REPO" checkout -q "$branch"
  git -C "$REPO" branch -q --set-upstream-to=up "$branch" 2>/dev/null

  # Behind upstream, but the graph still matches this worktree: nothing to do, so
  # silence. Being behind is a git fact, and reporting it here would make silence
  # useless as a signal.
  run run_drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Once a node actually drifts, the same fact becomes useful context and appears.
  printf 'class A { int x; }\n' > "$REPO/mod-a/a.java"
  commit_all edit
  run run_drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mod A	content changed in 1 of its files"* ]]
  [[ "$output" == *"commits behind up, as of the last fetch"* ]]

  # Read-only throughout: HEAD must not have moved and nothing may be fetched in.
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "$branch" ]
  [ ! -f "$REPO/mod-a/ahead.java" ]
}

@test "a divergent baseline is reported in both directions, and the file diff still holds" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # The real scenario, and the ordering matters: the release branch forks *before*
  # the commit the node was built at, so the baseline is not on this checkout's line.
  # Branching from the baseline itself would leave it an ancestor and prove nothing.
  local fork; fork="$(git_head)"
  printf 'class A { int mainline; }\n' > "$REPO/mod-a/a.java"
  commit_all mainline-work
  local base; base="$(git_head)"
  stage_node "Mod A" "$base" mod-a/a.java mod-a/b.java
  stage_index "Mod A.md" mod-a/a.java mod-a/b.java

  # Diverge without leaving the branch. A namespace belongs to one branch, so
  # checking another one out has no namespace at all rather than a divergent
  # baseline -- that case is covered separately. Resetting to the fork point and
  # committing elsewhere reproduces the identical topology (the recorded baseline
  # is no longer an ancestor of HEAD) on the branch the graph actually describes,
  # which is what a rebase or a reset does in real use.
  git -C "$REPO" reset --hard -q "$fork"
  git -C "$REPO" rm -q mod-a/b.java
  commit_all diverged-line
  ! git -C "$REPO" merge-base --is-ancestor "$base" HEAD

  run run_drift
  [ "$status" -eq 0 ]
  # A one-directional count would claim "1 commits since baseline" and hide that the
  # baseline's line has work this checkout does not.
  [[ "$output" == *"is not an ancestor of HEAD"* ]]
  [[ "$output" == *"the graph describes a different line"* ]]
  [[ "$output" != *"commits since baseline"* ]]
  # The tree diff is still correct and useful: b.java genuinely is not here.
  [[ "$output" == *"Mod A	1 of its files are gone"* ]]
}

@test "on a branch with no namespace, drift says so rather than reporting clean" {
  # The other half of the per-branch model, and the one that must not be silent:
  # a namespace describes one branch, so another branch has none. Exit 1 is
  # "could not run", never "clean" -- silence here would read as a graph that
  # matches, which is the conflation the keying exists to remove.
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  local base; base="$(git_head)"
  stage_node "Mod A" "$base" mod-a/a.java
  stage_index "Mod A.md" mod-a/a.java

  run run_drift
  [ "$status" -eq 0 ]

  git -C "$REPO" checkout -q -b some-other-branch
  run run_drift
  [ "$status" -eq 1 ]
  [[ "$output" != *"is not an ancestor of HEAD"* ]]
}

@test "one diff per distinct baseline, not one per node" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  local base; base="$(git_head)"
  # Three nodes sharing a baseline, as a single build run produces.
  stage_node "Mod A" "$base" mod-a/a.java
  stage_node "Mod B" "$base" mod-a/b.java
  stage_node "Docs" "$base" docs/guide.md
  stage_index "Mod A.md" mod-a/a.java

  printf 'class A { int x; }\n' > "$REPO/mod-a/a.java"
  commit_all edit

  run run_drift
  [ "$status" -eq 0 ]
  # The commits-since line is per baseline, so a shared baseline reports once.
  [ "$(printf '%s\n' "$output" | grep -c 'commits since baseline')" -eq 1 ]
}

@test "arguments are a usage error" {
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Mod A" "$(git_head)" mod-a/a.java
  stage_index "Mod A.md" mod-a/a.java

  run run_drift extra
  [ "$status" -eq 2 ]
}

@test "in a repo with no namespace it exits 1, not 2, even with bad arguments" {
  make_two_area_repo
  # Documents a real limitation rather than asserting it is ideal. The subcommand
  # name is validated before the preamble, but per-subcommand arity is checked
  # inside the subcommand, so a missing namespace masks a typo'd argument — the
  # exact confusion the early subcommand check exists to avoid. `stale` behaves the
  # same way; fixing it means hoisting arity out of every subcommand.
  run run_drift extra
  [ "$status" -eq 1 ]
  # It now names the reason on stderr rather than exiting mute -- but the reason
  # must be "no graph here", never anything a caller could read as a finding.
  [[ "$output" == *"no namespace covers"* ]]
  [[ "$output" != *"is not an ancestor"* ]]
}
