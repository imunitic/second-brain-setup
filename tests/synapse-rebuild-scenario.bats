#!/usr/bin/env bats
# Exercises the mechanical half of /synapse-rebuild against a repo with real
# history and real drift, using the same fake-curl vault the other suites use --
# no Obsidian, no network.
#
# /synapse-rebuild itself is a natural-language procedure, so what is testable is
# everything it delegates: the drift classification it triages on, the reseat path
# for rename-only nodes, the mechanical re-enumeration, the refusal to write an
# empty node after a branch switch, and whether the loop actually closes (drift
# silent again afterwards). Whether a prose patch is *good* is not testable here.
#
# The repo is deliberately big enough for change ratios to mean something: a
# five-file fixture cannot tell you whether "under ~10% -> patch" is a sensible cut.

load 'test_helper'

BIN="$REPO_ROOT/claude/bin"

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

in_repo() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_CAPTURE_DIR="$TEST_HOME/capture" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$@"
}

commit_all() { # commit_all <message>
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "$1"
}

ns() { echo "$VAULT/synapse/$(repo_name)"; }

# Four modules of 20 files each, so a two-file change is 10% of a node and a
# whole-module change is not.
make_project() {
  make_repo
  local m i
  for m in alpha beta gamma; do
    mkdir -p "$REPO/mod-$m/src/main/java"
    for i in $(seq 1 20); do
      printf 'class %s%02d { int v = %d; }\n' "$m" "$i" "$i" > "$REPO/mod-$m/src/main/java/${m}${i}.java"
    done
  done
  mkdir -p "$REPO/docs"
  for i in 1 2 3; do printf '# doc %d\n' "$i" > "$REPO/docs/d$i.md"; done
  commit_all project

  printf 'Alpha — the first module\t^mod-alpha/\t\n' > "$WORK/manifest.tsv"
  printf 'Beta — the second module\t^mod-beta/\t\n' >> "$WORK/manifest.tsv"
  printf 'Gamma — the third module\t^mod-gamma/\t\n' >> "$WORK/manifest.tsv"
  printf 'Docs — the documentation\t^docs/\t\n' >> "$WORK/manifest.tsv"
}

# Runs the full four-step build, as /synapse-init would.
build_namespace() {
  in_repo "$BIN/synapse-build-lists.sh" >/dev/null
  local nn title
  for nn in 01 02 03 04; do
    title="$(cat "$WORK/lists/$nn.title")"
    printf -- '---\nsummary: %s in one line.\n---\n\n## Summary\nProse for %s.\n\n## Crux\n```java\nclass alpha1 { int v = 1; }\n```\n' \
      "$title" "$title" > "$WORK/b-$nn.md"
  done
  in_repo "$BIN/synapse-push-nodes.sh" >/dev/null
  in_repo "$BIN/synapse-build-index.sh" >/dev/null
  cp "$TEST_HOME/capture/index-put.json" "$(ns)/_index.json"
  in_repo "$BIN/synapse-build-project-index.sh" >/dev/null
}

drift() { in_repo "$BIN/synapse-query.sh" drift; }

@test "a freshly built namespace has no drift" {
  make_project
  build_namespace

  run drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run in_repo "$BIN/synapse-query.sh" stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mixed drift is classified per node, and the ratios are measurable" {
  make_project
  build_namespace

  # Alpha: 2 of 20 files edited -> 10%, the patch case.
  printf 'class alpha1 { int v = 99; }\n' > "$REPO/mod-alpha/src/main/java/alpha1.java"
  printf 'class alpha2 { int v = 99; }\n' > "$REPO/mod-alpha/src/main/java/alpha2.java"
  # Beta: every file moved, content untouched -> the reseat case.
  git -C "$REPO" mv mod-beta/src/main/java mod-beta/src/main/kotlin
  # Gamma: one deletion plus three additions under the existing pattern.
  git -C "$REPO" rm -q mod-gamma/src/main/java/gamma1.java
  local i
  for i in 21 22 23; do
    printf 'class gamma%d {}\n' "$i" > "$REPO/mod-gamma/src/main/java/gamma$i.java"
  done
  # A whole new subsystem no manifest pattern covers.
  mkdir -p "$REPO/mod-delta/src/main/java"
  printf 'class delta1 {}\n' > "$REPO/mod-delta/src/main/java/delta1.java"
  commit_all drift

  run drift
  [ "$status" -eq 0 ]

  [[ "$output" == *"Alpha — the first module	content changed in 2 of its files"* ]]
  [[ "$output" == *"Beta — the second module	20 of its files were renamed"* ]]
  [[ "$output" == *"Gamma — the third module	1 of its files are gone"* ]]
  [[ "$output" == *"3 new paths already match a manifest pattern"* ]]
  [[ "$output" == *"1 new paths match no manifest pattern"* ]]
  [[ "$output" == *"mod-delta/src/main/java/delta1.java"* ]]
  # Docs was not touched and must not be flagged.
  [[ "$output" != *"Docs — the documentation	content changed"* ]]

  # The triage input: changed-over-total per node. Alpha is 2/20, which is the
  # boundary the command's "under ~10% -> patch" rule of thumb refers to.
  run in_repo "$BIN/synapse-query.sh" sources "Alpha — the first module" --count
  [ "$output" -eq 20 ]
}

@test "reseat: a rename-only node is rebuilt from its own body, with no re-reading" {
  make_project
  build_namespace
  local before
  before="$(in_repo "$BIN/synapse-query.sh" body "Beta — the second module")"

  git -C "$REPO" mv mod-beta/src/main/java mod-beta/src/main/kotlin
  commit_all rename-beta

  run drift
  [[ "$output" == *"Beta — the second module	20 of its files were renamed"* ]]

  # The documented recipe: recover the prose from the node itself, drop the
  # trailing `## Sources` block (the writer regenerates it), re-enumerate, write
  # back. No source file is read, and the work dir's b-NN.md is not consulted --
  # which is what makes this work on a machine that never built the namespace.
  in_repo "$BIN/synapse-build-lists.sh" --reenumerate >/dev/null
  in_repo "$BIN/synapse-query.sh" body "Beta — the second module" \
    | awk '/^## Sources$/ { exit } { print }' > "$WORK/reseat.md"
  rm -f "$WORK/b-02.md"

  run in_repo "$BIN/synapse-write-node.sh" --title "Beta — the second module" \
    --summary "Beta — the second module in one line." \
    --paths "$WORK/lists/02.txt" --body "$WORK/reseat.md"
  [ "$status" -eq 0 ]

  # Prose survived byte-for-byte, minus the regenerated Sources mirror.
  local after
  after="$(in_repo "$BIN/synapse-query.sh" body "Beta — the second module" \
    | awk '/^## Sources$/ { exit } { print }')"
  [ "$after" = "$(awk '/^## Sources$/ { exit } { print }' <<< "$before")" ]

  # And the node no longer drifts: paths reseated, baseline re-recorded.
  in_repo "$BIN/synapse-build-index.sh" >/dev/null
  cp "$TEST_HOME/capture/index-put.json" "$(ns)/_index.json"
  run drift
  [[ "$output" != *"Beta — the second module"* ]]
}

@test "re-enumeration claims new files under existing patterns, without touching prose" {
  make_project
  build_namespace
  local i
  for i in 21 22 23; do
    printf 'class gamma%d {}\n' "$i" > "$REPO/mod-gamma/src/main/java/gamma$i.java"
  done
  commit_all adds

  run drift
  [[ "$output" == *"3 new paths already match a manifest pattern"* ]]

  in_repo "$BIN/synapse-build-lists.sh" --reenumerate >/dev/null
  [ "$(wc -l < "$WORK/lists/03.txt" | tr -d ' ')" -eq 23 ]

  # Rewriting the node with the wider list is mechanical; the prose is unchanged.
  in_repo "$BIN/synapse-query.sh" body "Gamma — the third module" \
    | awk '/^## Sources$/ { exit } { print }' > "$WORK/g.md"
  run in_repo "$BIN/synapse-write-node.sh" --title "Gamma — the third module" \
    --summary "Gamma — the third module in one line." \
    --paths "$WORK/lists/03.txt" --body "$WORK/g.md"
  [ "$status" -eq 0 ]
  run in_repo "$BIN/synapse-query.sh" sources "Gamma — the third module" --count
  [ "$output" -eq 23 ]
}

@test "a branch switch that removes a module leaves an empty list, and nothing is written" {
  make_project
  build_namespace
  local fork; fork="$(git -C "$REPO" rev-parse HEAD)"
  local main; main="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"

  # Mainline gains a commit after the fork point, so the recorded baseline is not
  # an ancestor of the release branch -- the real branch-switch topology.
  printf 'class alpha1 { int v = 2; }\n' > "$REPO/mod-alpha/src/main/java/alpha1.java"
  commit_all mainline
  build_namespace

  git -C "$REPO" checkout -q -b release "$fork"
  git -C "$REPO" rm -rq mod-gamma
  commit_all release-drops-gamma

  run drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not an ancestor of HEAD"* ]]
  [[ "$output" == *"Gamma — the third module	20 of its files are gone"* ]]

  in_repo "$BIN/synapse-build-lists.sh" --reenumerate >/dev/null
  # The subsystem does not exist on this line at all.
  [ ! -s "$WORK/lists/03.txt" ]

  # The writer must refuse rather than emit a node with no sources, and the node
  # already in the vault must be left intact -- its ## Notes is unrecoverable.
  run in_repo "$BIN/synapse-write-node.sh" --title "Gamma — the third module" \
    --summary "x" --paths "$WORK/lists/03.txt" --body "$WORK/b-03.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty path list"* ]]
  [ -f "$(ns)/Gamma — the third module.md" ]
  grep -q '^## Notes$' "$(ns)/Gamma — the third module.md"

  # And the driver reports it rather than aborting the whole run.
  run in_repo "$BIN/synapse-push-nodes.sh" 03
  [ "$status" -eq 1 ]
  [[ "$output" == *"03	SKIP (no list/title)"* || "$output" == *"03	FAILED"* ]]
  git -C "$REPO" checkout -q "$main"
}

@test "the loop closes: after rebuilding every flagged node, drift goes silent" {
  make_project
  build_namespace

  printf 'class alpha1 { int v = 99; }\n' > "$REPO/mod-alpha/src/main/java/alpha1.java"
  git -C "$REPO" mv mod-beta/src/main/java mod-beta/src/main/kotlin
  printf 'class gamma21 {}\n' > "$REPO/mod-gamma/src/main/java/gamma21.java"
  commit_all mixed

  run drift
  [ -n "$output" ]

  # The mechanical phase, then a rewrite of each flagged node from its own prose.
  in_repo "$BIN/synapse-build-lists.sh" --reenumerate >/dev/null
  local nn title
  for nn in 01 02 03; do
    title="$(cat "$WORK/lists/$nn.title")"
    in_repo "$BIN/synapse-query.sh" body "$title" \
      | awk '/^## Sources$/ { exit } { print }' > "$WORK/r-$nn.md"
    in_repo "$BIN/synapse-write-node.sh" --title "$title" --summary "$title in one line." \
      --paths "$WORK/lists/$nn.txt" --body "$WORK/r-$nn.md" >/dev/null
  done
  in_repo "$BIN/synapse-build-index.sh" >/dev/null
  cp "$TEST_HOME/capture/index-put.json" "$(ns)/_index.json"
  in_repo "$BIN/synapse-build-project-index.sh" >/dev/null

  run drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run in_repo "$BIN/synapse-query.sh" stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
