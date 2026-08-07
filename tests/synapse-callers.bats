#!/usr/bin/env bats
# Tests `synapse-query.sh callers` -- the repo-wide "who calls this name" lookup
# over the flat index synapse-build-refs.sh writes.
#
# Kept in its own file rather than added to synapse-query.bats because the
# subcommand deliberately shares none of that file's setup: no vault, no Obsidian
# REST stub, no namespace, no nodes. That independence is the property under
# test, so a setup that provided those anyway could not detect losing it.

load 'test_helper'

QUERY="$REPO_ROOT/claude/bin/synapse-query.sh"
BUILD="$REPO_ROOT/claude/bin/synapse-build-refs.sh"

setup() {
  common_setup
  make_repo "ssh://git@example.invalid/x/repo.git"
  WORK_DIR="$TEST_HOME/work"
  mkdir -p "$WORK_DIR"
  CACHE="$WORK_DIR/_tags_cache.json"
  INDEX="$WORK_DIR/_refs.tsv"
}

teardown() {
  common_teardown
}

tagline() { # tagline <padded-name> <kind> <def|ref> <row> <expression>
  printf '%s\t | %s\t%s (%s, 13) - (%s, 39) `%s`' "$1" "$2" "$3" "$4" "$4" "$5"
}

# A cache with one definition, one call, and one non-call reference -- the three
# cases the default filter has to tell apart.
seed_index() {
  local d c i
  d="$(tagline 'doThing   ' 'method ' 'def' 10 'public void doThing() {')"
  c="$(tagline 'doThing   ' 'call   ' 'ref' 20 'svc.doThing();')"
  i="$(tagline 'doThing   ' 'implementation' 'ref' 30 'class Impl implements doThing {')"
  jq -n --arg t "$d
$c
$i" '{"src/A.java": {hash: "a", unsupported: false, tags: $t}}' > "$CACHE"
  "$BUILD" --cache "$CACHE" --out "$INDEX" 2>/dev/null
}

run_callers() {
  cd "$REPO" || return 1
  PATH="$FAKE_BIN:$PATH" SYNAPSE_WORK_DIR="$WORK_DIR" "$QUERY" callers "$@"
}

@test "callers: default returns call sites only, as path:line<TAB>expression" {
  seed_index
  run run_callers doThing
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(printf '%s' "${lines[0]}" | cut -f1)" = "src/A.java:20" ]
  [ "$(printf '%s' "${lines[0]}" | cut -f2)" = "svc.doThing();" ]
}

# A `ref` is not the same as a call: `implements Foo` is a reference too, and
# filtering on reftype alone would report it as a caller.
@test "callers: a non-call reference is not reported as a caller" {
  seed_index
  run run_callers doThing
  [ "$status" -eq 0 ]
  [[ "$output" != *"implements"* ]]
}

@test "callers: --all returns defs and every ref, with reftype and kind columns" {
  seed_index
  run run_callers doThing --all
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  run bash -c "printf '%s\n' \"\$1\" | cut -f1 | LC_ALL=C sort -u | tr '\n' ' '" _ "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"def"* ]]
  [[ "$output" == *"ref"* ]]
}

# The whole point of dispatching before the preamble. If this regresses, callers
# starts failing in exactly the repos it is most useful in.
@test "callers: needs no vault, no namespace and no nodes" {
  seed_index
  rm -f "$HOME/.claude/synapse.conf"
  rm -rf "$VAULT"
  run run_callers doThing
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

# Zero rows from a built index means "checked, not called". A missing index must
# not be able to say the same thing, or absence of evidence reads as evidence.
@test "callers: a missing index is exit 1 naming the fix, not silent success" {
  run run_callers doThing
  [ "$status" -eq 1 ]
  [[ "$output" == *"synapse-build-refs.sh"* ]]
}

@test "callers: a name that is present but never called is silent, exit 0" {
  local d
  d="$(tagline 'lonely    ' 'method ' 'def' 3 'void lonely() {')"
  jq -n --arg t "$d" '{"src/A.java": {hash: "a", unsupported: false, tags: $t}}' > "$CACHE"
  "$BUILD" --cache "$CACHE" --out "$INDEX" 2>/dev/null

  run run_callers lonely
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "callers: matching is exact, not prefix -- look alone would over-report" {
  local a b
  a="$(tagline 'run       ' 'call   ' 'ref' 5 'a.run();')"
  b="$(tagline 'runFast   ' 'call   ' 'ref' 6 'a.runFast();')"
  jq -n --arg t "$a
$b" '{"src/A.java": {hash: "a", unsupported: false, tags: $t}}' > "$CACHE"
  "$BUILD" --cache "$CACHE" --out "$INDEX" 2>/dev/null

  run run_callers run
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"a.run();"* ]]
  [[ "$output" != *"runFast"* ]]
}

# The binary search and the sort that produced the file must agree on ordering.
# They do so via LC_ALL=C on both sides; a disagreement returns nothing, which is
# indistinguishable from "not called", so it is asserted rather than reviewed.
@test "callers: the look fast path agrees with a full scan over the index" {
  local t=""
  for n in alpha Beta gamma _under zz9 Aardvark run runFast; do
    t="$t$(tagline "$(printf '%-10s' "$n")" 'call   ' 'ref' 5 "x.$n();")
"
  done
  jq -n --arg t "$t" '{"src/A.java": {hash: "a", unsupported: false, tags: $t}}' > "$CACHE"
  "$BUILD" --cache "$CACHE" --out "$INDEX" 2>/dev/null

  for n in alpha Beta gamma _under zz9 Aardvark run runFast; do
    scan="$(LC_ALL=C awk -F'\t' -v n="$n" '$1==n && $2=="ref" && $3=="call" { print $4 "\t" $5 }' "$INDEX")"
    got="$(run_callers "$n")"
    [ "$got" = "$scan" ] || {
      echo "disagreement for '$n'"; echo "look: $got"; echo "scan: $scan"; return 1
    }
  done
}

@test "callers: a name containing regex metacharacters is matched literally" {
  local a
  a="$(tagline 'a.b       ' 'call   ' 'ref' 5 'x.a.b();')"
  jq -n --arg t "$a" '{"src/A.java": {hash: "a", unsupported: false, tags: $t}}' > "$CACHE"
  "$BUILD" --cache "$CACHE" --out "$INDEX" 2>/dev/null

  run run_callers 'a.b'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  # 'axb' must not match the '.' as a wildcard.
  run run_callers 'axb'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "callers: usage errors are exit 2" {
  seed_index
  run run_callers
  [ "$status" -eq 2 ]
  run run_callers doThing --nonsense
  [ "$status" -eq 2 ]
  run run_callers doThing extra-arg
  [ "$status" -eq 2 ]
}
