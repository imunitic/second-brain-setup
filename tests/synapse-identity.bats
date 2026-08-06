#!/usr/bin/env bats
# Tests claude/bin/synapse-identity.sh -- the one place a Synapse namespace name
# is derived. Everything else in the suite depends on this agreeing with itself
# across components, which is the whole reason the logic stopped being five
# inline copies.
#
# Sourced rather than executed: the library deliberately sets no shell options,
# so a test that ran it as a script would not exercise how callers actually use
# it.

load 'test_helper'

setup() {
  common_setup
  # shellcheck disable=SC1091
  . "$HOME/.claude/bin/synapse-identity.sh"
}

teardown() { common_teardown; }

@test "the scratch dir is not inside a git repo -- the isolation everything rests on" {
  # Not testing shipped code: pinning the invariant the whole suite assumes. It
  # was silently false on a machine whose TMPDIR pointed inside a git repo (an
  # Emacs-hosted terminal sets it to ~/.emacs.d/var/tmp), which made every
  # "this is not a git repo" assertion pass for the wrong reason. Nothing
  # asserted it, so nothing noticed.
  run git -C "$TEST_HOME" rev-parse --show-toplevel
  [ "$status" -ne 0 ]
}

@test "repo name comes from the remote, not the directory" {
  make_repo "ssh://git@example.invalid:7999/syr/syrius3.git"
  [ "$(synapse_repo_name "$REPO")" = "syrius3" ]
}

@test "repo name strips .git and survives other remote URL shapes" {
  make_repo "git@github.com:someone/my-project.git"
  [ "$(synapse_repo_name "$REPO")" = "my-project" ]

  git -C "$REPO" remote set-url origin "https://example.invalid/org/plain-http"
  [ "$(synapse_repo_name "$REPO")" = "plain-http" ]
}

@test "no remote at all: falls back to the toplevel basename, never an error" {
  make_repo
  [ "$(synapse_repo_name "$REPO")" = "$(basename "$REPO")" ]
  run synapse_namespace "$REPO"
  [ "$status" -eq 0 ]
}

@test "no origin but another remote: uses the first listed one" {
  make_repo
  git -C "$REPO" remote add upstream "ssh://git@example.invalid/x/from-upstream.git"
  [ "$(synapse_remote "$REPO")" = "ssh://git@example.invalid/x/from-upstream.git" ]
  [ "$(synapse_repo_name "$REPO")" = "from-upstream" ]
}

@test "branch name has slashes replaced, so it stays one directory" {
  make_repo "ssh://git@example.invalid/x/proj.git"
  git -C "$REPO" checkout -q -b feature/CORE-101490-deployment-mode
  [ "$(synapse_branch "$REPO")" = "feature-CORE-101490-deployment-mode" ]
  [ "$(synapse_namespace "$REPO")" = "proj@feature-CORE-101490-deployment-mode" ]
}

@test "detached HEAD is refused with a reason, never keyed as 'HEAD'" {
  make_repo "ssh://git@example.invalid/x/proj.git"
  git -C "$REPO" checkout -q --detach HEAD

  run synapse_branch "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"detached HEAD"* ]]

  run synapse_namespace "$REPO"
  [ "$status" -eq 1 ]
  # and it must not have printed a usable-looking key on the way out
  [[ "$output" != *"proj@HEAD"* ]]
}

@test "a linked worktree of the same repo resolves to a DIFFERENT namespace" {
  # The bug this task exists to fix: a worktree used to resolve to its own
  # directory basename, which no namespace had. It now resolves by branch, so
  # the worktree and its parent differ only because they are on different
  # branches -- which git enforces.
  make_repo "ssh://git@example.invalid/x/proj.git"
  local main_branch; main_branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  git -C "$REPO" worktree add -q "$TEST_HOME/wt" -b feature/x

  [ "$(synapse_namespace "$REPO")" = "proj@$main_branch" ]
  [ "$(synapse_namespace "$TEST_HOME/wt")" = "proj@feature-x" ]

  # The repo half must match: same repo, so the directory difference is invisible.
  [ "$(synapse_repo_name "$REPO")" = "$(synapse_repo_name "$TEST_HOME/wt")" ]

  git -C "$REPO" worktree remove --force "$TEST_HOME/wt"
}

@test "git refuses one branch in two worktrees, which is what makes the key complete" {
  # Not testing our code -- pinning the git guarantee the design rests on, so a
  # future git that relaxed it would fail here rather than silently produce two
  # checkouts claiming one namespace.
  make_repo "ssh://git@example.invalid/x/proj.git"
  git -C "$REPO" branch -q feat
  git -C "$REPO" worktree add -q "$TEST_HOME/w1" feat

  run git -C "$REPO" worktree add "$TEST_HOME/w2" feat
  [ "$status" -ne 0 ]
  [[ "$output" == *"already used by worktree"* ]]

  git -C "$REPO" worktree remove --force "$TEST_HOME/w1"
}

@test "two clones of one repo on one branch share a namespace, by design" {
  make_repo "ssh://git@example.invalid/x/proj.git"
  local clone="$TEST_HOME/second-clone"
  git clone -q "$REPO" "$clone" 2>/dev/null
  git -C "$clone" remote set-url origin "ssh://git@example.invalid/x/proj.git"

  # Same committed code, so the same namespace is correct rather than a clash --
  # any divergence between them is ordinary drift the graph already reports.
  [ "$(synapse_repo_name "$clone")" = "$(synapse_repo_name "$REPO")" ]
}

@test "a repo with no commits yet still resolves: the branch exists, unborn" {
  # `rev-parse --abbrev-ref HEAD` fails outright here ("ambiguous argument"),
  # which would have made a fresh repo mid-init look like a detached HEAD.
  mkdir -p "$TEST_HOME/fresh"
  git init -q "$TEST_HOME/fresh"
  local b; b="$(git -C "$TEST_HOME/fresh" symbolic-ref --short HEAD)"
  [ "$(synapse_branch "$TEST_HOME/fresh")" = "$b" ]
  [ "$(synapse_namespace "$TEST_HOME/fresh")" = "fresh@$b" ]
}

@test "characters that are legal in a git ref but not in a filename are translated" {
  make_repo "ssh://git@example.invalid/x/proj.git"
  # `<` and `>` pass git's check-ref-format but are not safe as filenames.
  git -C "$REPO" checkout -q -b 'odd<name>here'
  [ "$(synapse_branch "$REPO")" = "odd-name-here" ]
}
