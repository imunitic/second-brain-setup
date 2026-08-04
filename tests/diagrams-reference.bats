#!/usr/bin/env bats
# Tests docs/generate-diagrams.sh -- the .mmd -> .png renderer and its --check
# mode. The point of --check is that a stale diagram is worse than a missing one:
# it is confidently wrong, and nothing about looking at it says so.
#
# Rendering needs mermaid-cli (which needs a headless Chromium), so the tests
# that actually render skip when mmdc is absent. The --check logic is pure
# shell/hashing and is tested unconditionally, because that is the part wired
# into CI-style verification.

load 'test_helper'

GEN="$REPO_ROOT/docs/generate-diagrams.sh"

setup() {
  common_setup
  # A throwaway copy of the generator's layout, so nothing here touches the real
  # docs/diagrams.
  WORK="$TEST_HOME/docs"
  mkdir -p "$WORK/diagrams"
  cp "$GEN" "$WORK/generate-diagrams.sh"
  GEN_COPY="$WORK/generate-diagrams.sh"
}

teardown() { common_teardown; }

write_mmd() { # write_mmd <name> <label>
  printf 'flowchart TB\n    A["%s"] --> B["done"]\n' "$2" > "$WORK/diagrams/$1.mmd"
}

stamp() { # stamp <name> -- record the CURRENT hash, as a successful render would
  local h; h="$(sha256_stdin < "$WORK/diagrams/$1.mmd")"
  printf '%s\t%s\n' "$1" "$h" >> "$WORK/diagrams/.rendered"
}

@test "check: a source with no png at all is reported" {
  write_mmd one "hello"
  run bash "$GEN_COPY" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"one (no .png)"* ]]
}

@test "check: a png whose source has since changed is reported as stale" {
  write_mmd one "hello"
  : > "$WORK/diagrams/one.png"
  stamp one
  run bash "$GEN_COPY" --check
  [ "$status" -eq 0 ]

  # Editing the source without re-rendering is exactly the failure this catches.
  write_mmd one "hello, revised"
  run bash "$GEN_COPY" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"source changed since it was rendered"* ]]
}

@test "check: passes when every png matches its recorded source hash" {
  write_mmd one "a"; : > "$WORK/diagrams/one.png"; stamp one
  write_mmd two "b"; : > "$WORK/diagrams/two.png"; stamp two
  run bash "$GEN_COPY" --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check: one stale diagram does not mask the others, and all are named" {
  write_mmd one "a"; : > "$WORK/diagrams/one.png"; stamp one
  write_mmd two "b"; : > "$WORK/diagrams/two.png"; stamp two
  write_mmd three "c"   # never rendered
  write_mmd one "a2"    # edited after rendering

  run bash "$GEN_COPY" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"one"* ]]
  [[ "$output" == *"three"* ]]
  [[ "$output" == *"2 diagram(s) out of date"* ]]
}

@test "no .mmd sources at all is an error, not a silent pass" {
  run bash "$GEN_COPY" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no .mmd sources"* ]]
}

@test "an unknown flag exits 2, and --help exits 0" {
  write_mmd one "a"
  run bash "$GEN_COPY" --bogus
  [ "$status" -eq 2 ]
  run bash "$GEN_COPY" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# mermaid-cli drives a headless Chromium that puppeteer caches under the real
# $HOME, which common_setup swaps out -- so these two hand that one path back.
render() { PUPPETEER_CACHE_DIR="$REAL_HOME/.cache/puppeteer" bash "$GEN_COPY" "$@"; }
can_render() {
  command -v mmdc >/dev/null || skip "mmdc not installed"
  [ -d "$REAL_HOME/.cache/puppeteer" ] || skip "no puppeteer chromium cache"
}

@test "render: produces a png and records the source hash" {
  can_render
  write_mmd one "hello"
  run render
  [ "$status" -eq 0 ]
  [ -s "$WORK/diagrams/one.png" ]
  # and --check is satisfied by its own output, which is the loop closing
  run render --check
  [ "$status" -eq 0 ]
}

@test "render: leaves other diagrams' stamps alone" {
  can_render
  write_mmd keep "untouched"; : > "$WORK/diagrams/keep.png"; stamp keep
  write_mmd new "fresh"
  run render
  [ "$status" -eq 0 ]
  # rewriting the stamp file must not drop the entry it was not rendering
  grep -q '^keep	' "$WORK/diagrams/.rendered"
  grep -q '^new	' "$WORK/diagrams/.rendered"
}

@test "the repo's own diagrams are current" {
  run bash "$GEN" --check
  [ "$status" -eq 0 ]
}
