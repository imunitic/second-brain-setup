#!/usr/bin/env bats
# Tests claude/bin/synapse-rank.sh -- the tiered ranking that decides what is
# worth READING when authoring a node's prose. Coverage is not at stake here:
# `sources` stays exhaustive, and nothing this script does can remove a file
# from the graph. Only reading order changes.
#
# tree-sitter is the fake in tests/fixtures/fake-bin, which emits one tag per
# `symbol:` line (a definition) and per `ref:` line (a reference) in the file.
# File SIZE is real, so a fixture controls density by how much filler it
# carries -- which is the whole point of the code tier.

load 'test_helper'

SCRIPT="$REPO_ROOT/claude/bin/synapse-rank.sh"

setup() {
  common_setup
  mkdir -p "$HOME/.claude/bin"
  cp "$REPO_ROOT/claude/bin/synapse-tags.sh" "$HOME/.claude/bin/synapse-tags.sh"
  chmod +x "$HOME/.claude/bin/synapse-tags.sh"
  printf '%s' '{"java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
  SRC="$TEST_HOME/sources.txt"
  : > "$SRC"
}

teardown() {
  common_teardown
}

# A file with the given definitions, plus `pad` filler bytes. Filler is what
# separates "declares a lot" from "is merely large".
src() { # src <path> <pad-bytes> <symbol>...
  local path="$REPO/$1" pad="$2"; shift 2
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local s
  for s in "$@"; do printf 'symbol:%s\n' "$s" >> "$path"; done
  [ "$pad" -eq 0 ] || head -c "$pad" /dev/zero | tr '\0' 'x' >> "$path"
}

# Registers a path in the sources list under test.
want() { printf '%s\n' "$@" >> "$SRC"; }

commit_repo() {
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
}

run_rank() {
  PATH="$FAKE_BIN:$PATH" "$SCRIPT" --sources "$SRC" --repo "$REPO" "$@"
}

# bats merges stderr into $output, and this script reports its per-tier counts
# there. Every assertion about the RANKING therefore has to filter to the data
# lines first, or the summary line counts as a result.
data() { # data <output>
  grep -E '^(code|dsl)	' <<< "$1" || true
}

# The rank (1-based) of a path within its tier, or empty when absent.
rank_of() { # rank_of <path> <output>
  data "$2" | awk -F'\t' -v p="$1" '$3 == p { print NR }'
}

@test "an oversized file does not outrank a small one with the same definitions" {
  # The finding the code tier exists for: raw definition counts rank generated
  # constant tables and wide accessor classes first, which is the opposite of
  # useful. Both files here declare exactly the same symbols; only size differs.
  git init -q "$REPO"
  src core/src/Service.java   0     Alpha Beta Gamma
  src core/src/Generated.java 40000 Alpha Beta Gamma
  commit_repo
  want core/src/Service.java core/src/Generated.java

  run run_rank
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/Service.java "$output")" -lt "$(rank_of core/src/Generated.java "$output")" ]
}

@test "raw counts alone would give the opposite answer" {
  # Pins that normalising is what decides it, rather than the small file
  # happening to win for some other reason: here the big file declares strictly
  # MORE symbols and must still rank below.
  git init -q "$REPO"
  src core/src/Service.java   0     Alpha Beta
  src core/src/Generated.java 40000 One Two Three Four Five Six Seven Eight
  commit_repo
  want core/src/Service.java core/src/Generated.java

  run run_rank
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/Service.java "$output")" -lt "$(rank_of core/src/Generated.java "$output")" ]
}

@test "references do not count as definitions" {
  # A summary is made of what a subsystem DECLARES. A file that merely calls a
  # lot of things is not thereby a good thing to read first.
  git init -q "$REPO"
  src core/src/Declarer.java 0 Alpha Beta Gamma Delta
  mkdir -p "$REPO/core/src"
  : > "$REPO/core/src/Caller.java"
  for i in 1 2 3 4 5 6 7 8 9; do printf 'ref:Thing%s\n' "$i" >> "$REPO/core/src/Caller.java"; done
  commit_repo
  want core/src/Declarer.java core/src/Caller.java

  run run_rank
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/Declarer.java "$output")" -lt "$(rank_of core/src/Caller.java "$output")" ]
}

@test "a file that parsed to no definitions is ranked last, not dropped" {
  git init -q "$REPO"
  src core/src/Real.java 0 Alpha Beta
  printf 'notags\n' > "$REPO/core/src/Empty.java"
  commit_repo
  want core/src/Real.java core/src/Empty.java

  run run_rank
  [ "$status" -eq 0 ]
  [ -n "$(rank_of core/src/Empty.java "$output")" ]
  [ "$(rank_of core/src/Real.java "$output")" -lt "$(rank_of core/src/Empty.java "$output")" ]
}

# --- dsl tier --------------------------------------------------------------

@test "a declaration ranks its consumer, resolved by stem prefix" {
  # `Kunde.gui` is a declaration; `KundeController.java` is the code that binds
  # it and carries the domain verbs. The declaration itself is never ranked.
  git init -q "$REPO"
  src core/src/KundeController.java 0 Alpha
  printf 'declaration\n' > "$REPO/core/src/Kunde.gui"
  commit_repo
  want core/src/Kunde.gui core/src/KundeController.java

  run run_rank
  [ "$status" -eq 0 ]
  [ -n "$(data "$output" | awk -F'\t' '$1 == "dsl" && $3 == "core/src/KundeController.java"')" ]
  # The .gui file is evidence, not a reading target.
  [ -z "$(data "$output" | awk -F'\t' '$3 == "core/src/Kunde.gui"')" ]
}

@test "the consumer hop is constrained to the declaration's own module" {
  # THE finding that makes the hop worth anything: generic stems match dozens
  # of unrelated classes across a large repo, so a stem-only match resolves to
  # whichever sorts first and is worse than no answer at all.
  git init -q "$REPO"
  src billing/src/AdresseHandler.java  0 Alpha
  src shipping/src/AdresseHandler.java 0 Beta
  printf 'declaration\n' > "$REPO/billing/src/Adresse.domvo"
  commit_repo
  want billing/src/Adresse.domvo billing/src/AdresseHandler.java shipping/src/AdresseHandler.java

  run run_rank
  [ "$status" -eq 0 ]
  [ -n "$(data "$output" | awk -F'\t' '$1 == "dsl" && $3 == "billing/src/AdresseHandler.java"')" ]
  [ -z "$(data "$output" | awk -F'\t' '$1 == "dsl" && $3 == "shipping/src/AdresseHandler.java"')" ]
}

@test "consumers rank by how many declarations they serve" {
  git init -q "$REPO"
  src core/src/BusyHandler.java 0 Alpha
  src core/src/IdleHandler.java 0 Beta
  # Both stems prefix `BusyHandler`, so both resolve to the same consumer.
  printf 'x\n' > "$REPO/core/src/Busy.domvo"
  printf 'x\n' > "$REPO/core/src/BusyHandler.domvo"
  printf 'x\n' > "$REPO/core/src/Idle.domvo"
  commit_repo
  want core/src/Busy.domvo core/src/BusyHandler.domvo core/src/Idle.domvo

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/BusyHandler.java "$output")" -lt "$(rank_of core/src/IdleHandler.java "$output")" ]
  [ "$(data "$output" | awk -F'\t' '$3 ~ /BusyHandler/ { print $2 }')" = "2" ]
}

@test "a consumer outside the node's own sources is still found" {
  # The code that uses a node's declarations is frequently the reason to read
  # it, and is not always a file the node itself owns.
  git init -q "$REPO"
  src core/src/KundeController.java 0 Alpha
  printf 'x\n' > "$REPO/core/src/Kunde.gui"
  commit_repo
  want core/src/Kunde.gui          # the controller is deliberately NOT listed

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ -n "$(data "$output" | awk -F'\t' '$3 == "core/src/KundeController.java"')" ]
}

@test "config and data with no consumer are unranked but counted" {
  # Scored zero and omitted from the ranking, still fully covered by `sources`
  # -- coverage and relevance are separate axes.
  git init -q "$REPO"
  src core/src/Real.java 0 Alpha
  printf 'a=1\n' > "$REPO/core/src/settings.properties"
  printf '{}\n'  > "$REPO/core/src/data.json"
  commit_repo
  want core/src/Real.java core/src/settings.properties core/src/data.json

  run run_rank
  [ "$status" -eq 0 ]
  [ -z "$(data "$output" | awk -F'\t' '$3 ~ /settings.properties|data.json/')" ]
  [[ "$output" == *"unranked 2"* ]]
}

@test "a stem under three characters makes no hop" {
  # Such a stem prefixes half the repo and tells you nothing.
  git init -q "$REPO"
  src core/src/AbcHandler.java 0 Alpha
  printf 'x\n' > "$REPO/core/src/Ab.domvo"
  commit_repo
  want core/src/Ab.domvo

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ -z "$(data "$output")" ]
}

# --- output shape ----------------------------------------------------------

@test "--top limits each tier, and --top 0 prints everything" {
  git init -q "$REPO"
  local i
  for i in $(seq 1 8); do src "core/src/F$i.java" 0 "Sym$i"; done
  commit_repo
  for i in $(seq 1 8); do want "core/src/F$i.java"; done

  run run_rank --top 3
  [ "$status" -eq 0 ]
  [ "$(data "$output" | wc -l | tr -d ' ')" -eq 3 ]

  run run_rank --top 0
  [ "$status" -eq 0 ]
  [ "$(data "$output" | wc -l | tr -d ' ')" -eq 8 ]
}

@test "--tier restricts the output to one tier" {
  git init -q "$REPO"
  src core/src/KundeController.java 0 Alpha
  printf 'x\n' > "$REPO/core/src/Kunde.gui"
  commit_repo
  want core/src/Kunde.gui core/src/KundeController.java

  run run_rank --tier code
  [ "$status" -eq 0 ]
  [ "$(data "$output" | awk -F'\t' '$1 != "code"' | wc -l | tr -d ' ')" -eq 0 ]

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ "$(data "$output" | awk -F'\t' '$1 != "dsl"' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "a node made entirely of config ranks nothing, and that is not a failure" {
  git init -q "$REPO"
  mkdir -p "$REPO/core/src"
  printf 'a=1\n' > "$REPO/core/src/settings.properties"
  commit_repo
  want core/src/settings.properties

  run run_rank
  [ "$status" -eq 0 ]
  [ -z "$(data "$output")" ]
}

@test "no per-file subprocess anywhere in the ranking path" {
  # A `wc -c` per path cost 15 minutes where a batched `stat` cost 3 seconds on
  # a real repo, and a fixture of eight files can never surface the difference.
  # The POC this replaces had TWO such loops -- a tags invocation and a size
  # check, both per file.
  # Comments stripped first: this script's own header explains the trap by
  # name, and a structural check that trips on the explanation is worse than
  # no check -- it would force the comment out to stay green.
  local code; code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
  [ "$(grep -c 'wc -c' <<< "$code")" -eq 0 ]
  [ "$(grep -c 'basename' <<< "$code")" -eq 1 ]
  grep -q 'xargs -0 stat' <<< "$code"
}

@test "usage and environment errors" {
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT"
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --sources "$SRC" --tier bogus
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --sources "$TEST_HOME/nope.txt"
  [ "$status" -eq 1 ]
}
