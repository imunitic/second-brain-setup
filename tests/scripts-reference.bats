#!/usr/bin/env bats
# Tests docs/generate-scripts-reference.sh, and asserts the committed
# docs/scripts.md is current. That second assertion is the point: it turns a stale
# reference into a failing test rather than a document that quietly describes a
# script as it used to be.

load 'test_helper'

GEN="$REPO_ROOT/docs/generate-scripts-reference.sh"

@test "the committed docs/scripts.md is up to date" {
  run bash "$GEN" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

@test "--check fails when a script's header has moved on" {
  # Simulate an edited header in a scratch copy of the repo, so the real tree is
  # untouched. A doc generated from the headers must notice.
  local scratch="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$scratch"
  cp -R "$REPO_ROOT/docs" "$REPO_ROOT/claude" "$scratch/"

  run bash "$scratch/docs/generate-scripts-reference.sh" --check
  [ "$status" -eq 0 ]

  printf '# a newly documented flag\n' >> "$scratch/claude/bin/synapse-build-index.sh"
  # Appending at the end changes nothing: extraction stops at the first
  # non-comment line, so only the header block matters.
  run bash "$scratch/docs/generate-scripts-reference.sh" --check
  [ "$status" -eq 0 ]

  # Editing inside the header block does change it.
  perl -0pi -e 's/^# Usage: synapse-build-index\.sh$/# Usage: synapse-build-index.sh [--force]/m' \
    "$scratch/claude/bin/synapse-build-index.sh"
  run bash "$scratch/docs/generate-scripts-reference.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"out of date"* ]]
}

@test "every script contributes a section and a fenced help block" {
  local scratch="$BATS_TEST_TMPDIR/gen"
  mkdir -p "$scratch"
  cp -R "$REPO_ROOT/docs" "$REPO_ROOT/claude" "$scratch/"
  run bash "$scratch/docs/generate-scripts-reference.sh"
  [ "$status" -eq 0 ]

  local expected actual
  expected="$(find "$REPO_ROOT/claude/bin" -name '*.sh' | wc -l | tr -d ' ')"
  actual="$(grep -c '^## `synapse-' "$scratch/docs/scripts.md")"
  [ "$actual" -eq "$expected" ]
  # Paired fences: one open and one close per script.
  [ "$(grep -c '^```$' "$scratch/docs/scripts.md")" -eq "$((expected * 2))" ]
}

@test "no fenced block in the reference is empty" {
  # Counting fences is not enough, and that gap shipped a broken page: an empty
  # block still opens and closes, so the pairing check above was satisfied by a
  # section whose help text had silently gone missing.
  run awk '
    /^```$/ { if (!inf) { inf = 1; n = 0 } else { inf = 0; if (n == 0) empty++ }; next }
    inf { n++ }
    END { print empty + 0 }
  ' "$REPO_ROOT/docs/scripts.md"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "a Usage line with a parenthetical is still extracted" {
  # The exact break: the marker was `^# Usage:` and synapse-identity.sh says
  # `# Usage (sourced, never executed):` -- it is sourced rather than run, so the
  # parenthetical is real information. A marker that misses produces TWO silent
  # defects, so both are asserted: the usage lines must be inside the fence, and
  # must NOT have been absorbed into the prose above it.
  local section
  section="$(awk '/^## `synapse-identity.sh`/ { p = 1; next }
                  p && /^## `/ { exit } p' "$REPO_ROOT/docs/scripts.md")"

  [[ "$section" == *'Usage (sourced, never executed):'* ]]
  # Inside the fence: everything before the opening ``` is prose.
  local prose
  prose="$(awk '/^```$/ { exit } { print }' <<< "$section")"
  [[ "$prose" != *"Usage"* ]]
  [[ "$prose" != *'synapse_namespace'* ]]
}

@test "a header with no Usage line fails the generator instead of emitting an empty block" {
  local scratch="$BATS_TEST_TMPDIR/nousage"
  mkdir -p "$scratch"
  cp -R "$REPO_ROOT/docs" "$REPO_ROOT/claude" "$scratch/"

  run bash "$scratch/docs/generate-scripts-reference.sh"
  [ "$status" -eq 0 ]

  # Strip the marker from one script's header.
  perl -0pi -e 's/^# Usage: synapse-build-index\.sh$/# Invocation: synapse-build-index.sh/m' \
    "$scratch/claude/bin/synapse-build-index.sh"

  run bash "$scratch/docs/generate-scripts-reference.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"synapse-build-index.sh"* ]]
  [[ "$output" == *"no '# Usage' line"* ]]

  # And --check refuses too, rather than reporting a stale doc for the wrong reason.
  run bash "$scratch/docs/generate-scripts-reference.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no '# Usage' line"* ]]
}

@test "the generated help matches what the script itself prints" {
  # The whole reason to generate rather than hand-write: --help and the reference
  # come from one block, so they cannot disagree.
  local from_script
  from_script="$(bash "$REPO_ROOT/claude/bin/synapse-write-node.sh" --help 2>&1)"
  local first_line
  first_line="$(printf '%s\n' "$from_script" | head -1)"
  grep -qF "$first_line" "$REPO_ROOT/docs/scripts.md"

  local last_line
  last_line="$(printf '%s\n' "$from_script" | grep -v '^$' | tail -1)"
  grep -qF "$last_line" "$REPO_ROOT/docs/scripts.md"
}

@test "a bad flag exits 2 with usage" {
  run bash "$GEN" --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}
