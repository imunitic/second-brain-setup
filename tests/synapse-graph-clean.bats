#!/usr/bin/env bats
# Tests claude/bin/synapse-graph-clean.sh -- the only destructive tool in Synapse.
# The bias throughout is toward keeping notes: every test that asserts a removal
# has a sibling asserting that a namespace which merely *looks* removable is left
# alone, because a false positive here destroys authored prose.
#
# No fake git: these need real refs, real upstream config and real pruning, which
# is the entire subject. The "remote" is a second local repo.

load 'test_helper'

SCRIPT="$REPO_ROOT/claude/bin/synapse-graph-clean.sh"

setup() {
  common_setup
  REMOTE_REPO="$TEST_HOME/remote.git"
}

teardown() { common_teardown; }

run_clean() {
  bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$SCRIPT" "$@"
}

# A repo with a real (local, bare) remote it can actually fetch from.
make_repo_with_remote() {
  git init -q --bare "$REMOTE_REPO"
  make_repo
  git -C "$REPO" remote add origin "$REMOTE_REPO"
  git -C "$REPO" push -q -u origin HEAD 2>/dev/null
}

# A namespace directory for $REPO on the given branch, with the branch field the
# cleaner reads. Content is a stand-in for the real thing -- what matters is that
# it is a directory of notes that must not vanish by accident.
make_namespace() { # make_namespace <branch>
  local branch="$1"
  local ns; ns="$(synapse_repo_for_test)@${branch//\//-}"
  mkdir -p "$VAULT/synapse/$ns"
  cat > "$VAULT/synapse/$ns/Index.md" <<EOF
---
title: "$ns — Synapse index"
node_type: synapse-index
project: $(synapse_repo_for_test)
branch: $branch
remote: "$REMOTE_REPO"
built_at: "test"
---
# $ns
EOF
  printf 'a node\n' > "$VAULT/synapse/$ns/Some Node.md"
  printf '%s' "$ns"
}

synapse_repo_for_test() {
  . "$HOME/.claude/bin/synapse-identity.sh"
  synapse_repo_name "$REPO"
}

ns_exists() { [ -d "$VAULT/synapse/$1" ]; }

@test "a branch whose upstream was deleted is removed" {
  make_repo_with_remote
  git -C "$REPO" checkout -q -b feature/gone
  git -C "$REPO" push -q -u origin feature/gone 2>/dev/null
  local ns; ns="$(make_namespace feature/gone)"
  ns_exists "$ns"

  # Merged and deleted on the remote, which is what the command exists for.
  git -C "$REPO" push -q origin --delete feature/gone 2>/dev/null

  run run_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed"* ]]
  ! ns_exists "$ns"
}

@test "a branch that was never pushed and still exists is kept" {
  # The failure that would matter most: deleting the namespace of the branch
  # someone is working on right now, because it has no remote counterpart.
  make_repo_with_remote
  git -C "$REPO" checkout -q -b local-only-wip
  local ns; ns="$(make_namespace local-only-wip)"

  run run_clean
  [ "$status" -eq 0 ]
  ns_exists "$ns"
  [[ "$output" != *"removed"* ]]
}

@test "a branch still present on the remote is kept" {
  make_repo_with_remote
  git -C "$REPO" checkout -q -b alive
  git -C "$REPO" push -q -u origin alive 2>/dev/null
  local ns; ns="$(make_namespace alive)"

  run run_clean
  [ "$status" -eq 0 ]
  ns_exists "$ns"
}

@test "a remoteless repo keeps every namespace whose branch still exists" {
  # Without the no-remote fallback the first run here would read every namespace
  # as "upstream gone" and wipe the lot.
  make_repo
  git -C "$REPO" checkout -q -b work
  local ns; ns="$(make_namespace work)"

  run run_clean
  [ "$status" -eq 0 ]
  ns_exists "$ns"
  [[ "$output" != *"removed"* ]]
}

@test "a gone branch in a remoteless repo is reported, never removed" {
  make_repo
  local ns; ns="$(make_namespace vanished)"

  run run_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"report"* ]]
  ns_exists "$ns"
}

@test "a branch absent locally with no upstream config is reported, not removed" {
  make_repo_with_remote
  local ns; ns="$(make_namespace never-existed)"

  run run_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"report"* ]]
  [[ "$output" != *"removed"* ]]
  ns_exists "$ns"
}

@test "a namespace with no branch field is reported rather than guessed at" {
  make_repo_with_remote
  local ns; ns="$(synapse_repo_for_test)@mystery"
  mkdir -p "$VAULT/synapse/$ns"
  printf -- '---\ntitle: "x"\nremote: "y"\n---\n' > "$VAULT/synapse/$ns/Index.md"

  run run_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"no branch field"* ]]
  ns_exists "$ns"
}

@test "the branch field, not the directory name, decides -- sanitizing is not reversible" {
  # The directory is `...@feature-slashed`, which could be branch `feature/slashed`
  # or a branch literally named `feature-slashed`. Only the field knows.
  make_repo_with_remote
  git -C "$REPO" checkout -q -b feature/slashed
  git -C "$REPO" push -q -u origin feature/slashed 2>/dev/null
  local ns; ns="$(make_namespace feature/slashed)"
  [ "$ns" = "$(synapse_repo_for_test)@feature-slashed" ]

  run run_clean
  [ "$status" -eq 0 ]
  ns_exists "$ns"   # still on the remote, so kept -- resolved via the field
}

@test "--dry-run reports what it would remove and deletes nothing" {
  make_repo_with_remote
  git -C "$REPO" checkout -q -b doomed
  git -C "$REPO" push -q -u origin doomed 2>/dev/null
  local ns; ns="$(make_namespace doomed)"
  git -C "$REPO" push -q origin --delete doomed 2>/dev/null
  git -C "$REPO" fetch --prune -q 2>/dev/null

  run run_clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would-remove"* ]]
  ns_exists "$ns"
}

@test "another repo's namespaces are never touched" {
  make_repo_with_remote
  mkdir -p "$VAULT/synapse/unrelated-project@main"
  printf -- '---\nbranch: main\n---\n' > "$VAULT/synapse/unrelated-project@main/Index.md"

  run run_clean
  [ "$status" -eq 0 ]
  [ -d "$VAULT/synapse/unrelated-project@main" ]
}

@test "nothing to clean says so, rather than exiting mute" {
  make_repo_with_remote
  run run_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to clean"* ]]
}

@test "outside a git repo it exits 1, and an unknown flag exits 2" {
  run bash -c 'cd "$1" && bash "$2"' _ "$TEST_HOME" "$SCRIPT"
  [ "$status" -eq 1 ]

  make_repo
  run run_clean --bogus
  [ "$status" -eq 2 ]
}
