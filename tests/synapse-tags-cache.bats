#!/usr/bin/env bats
# Tests claude/bin/synapse-tags-cache.sh -- the mechanical helper that keeps
# a per-project tags cache current for a set of path:hash pairs, re-tagging
# only what changed (in parallel) and never touching a file that's already
# current. Real `tree-sitter` is stubbed by tests/fixtures/fake-bin/tree-sitter
# (always emits one deterministic tag line) -- see that file's own comment
# for what it simulates -- so these tests exercise the cache's own diff/join
# logic, not tree-sitter itself.

load 'test_helper'

SCRIPT="$REPO_ROOT/claude/bin/synapse-tags-cache.sh"

setup() {
  common_setup
  GRAMMARS_DIR="$TEST_HOME/grammars"
  FAKE_TS_LOG="$TEST_HOME/ts.log"
  FAKE_GIT_LOG="$TEST_HOME/git.log"
  : > "$FAKE_TS_LOG"
  : > "$FAKE_GIT_LOG"
  printf '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
  # The helper shells out to the *installed* synapse-tags.sh, matching real
  # usage -- install the repo copy so the fake tree-sitter/git actually get
  # exercised by it.
  mkdir -p "$HOME/.claude/bin"
  cp "$REPO_ROOT/claude/bin/synapse-tags.sh" "$HOME/.claude/bin/synapse-tags.sh"
  chmod +x "$HOME/.claude/bin/synapse-tags.sh"
}

teardown() {
  common_teardown
}

run_cache() {
  PATH="$FAKE_BIN:$PATH" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    FAKE_TS_LOG="$FAKE_TS_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    "$SCRIPT" "$@"
}

# Writes N real .ml files under $REPO and a path:hash TSV for them (using
# real `git hash-object`, since the fake git only intercepts `clone`).
write_sample_files() { # write_sample_files <count>
  mkdir -p "$REPO"
  : > "$TEST_HOME/paths.tsv"
  local i
  for i in $(seq 1 "$1"); do
    printf 'let x_%d = %d\n' "$i" "$i" > "$REPO/sample_$i.ml"
    h="$(git -C "$REPO" hash-object "sample_$i.ml")"
    printf 'sample_%d.ml\t%s\n' "$i" "$h" >> "$TEST_HOME/paths.tsv"
  done
}

@test "cold cache: tags every requested file, records hash and tags" {
  make_repo
  write_sample_files 3

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  n="$(jq 'keys | length' "$TEST_HOME/_tags_cache.json")"
  [ "$n" -eq 3 ]
  [[ "$(jq -r '."sample_1.ml".tags' "$TEST_HOME/_tags_cache.json")" == *"FAKE_NAME"* ]]
  [ "$(jq -r '."sample_1.ml".unsupported' "$TEST_HOME/_tags_cache.json")" = "false" ]
  # Every requested file was tagged -- in ONE invocation, not three. Startup
  # and grammar load are nearly all of the per-file cost, so a per-file loop
  # here would undo the batching that exists upstream in synapse-tags.sh.
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 3 ]
  [ "$(grep -c '^tags ' "$FAKE_TS_LOG")" -eq 1 ]
}

@test "unchanged hashes: no re-tagging on a second run" {
  make_repo
  write_sample_files 3
  run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  : > "$FAKE_TS_LOG"

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "one file's hash changes: only that file is re-tagged, others untouched" {
  make_repo
  write_sample_files 3
  run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  before_2="$(jq -c '."sample_2.ml"' "$TEST_HOME/_tags_cache.json")"
  before_3="$(jq -c '."sample_3.ml"' "$TEST_HOME/_tags_cache.json")"

  printf 'let x_1 = 999 (* changed *)\n' > "$REPO/sample_1.ml"
  new_hash="$(git -C "$REPO" hash-object "$REPO/sample_1.ml")"
  sed -i.bak "s#^sample_1.ml\t.*#sample_1.ml\t$new_hash#" "$TEST_HOME/paths.tsv"
  : > "$FAKE_TS_LOG"

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  # Which file was tagged, not how many invocations happened: once tagging is
  # batched, an invocation count no longer distinguishes "re-tagged one file"
  # from "re-tagged all three in one call".
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 1 ]
  grep -qx 'path sample_1.ml' "$FAKE_TS_LOG"
  [ "$(jq -r '."sample_1.ml".hash' "$TEST_HOME/_tags_cache.json")" = "$new_hash" ]
  [ "$(jq -c '."sample_2.ml"' "$TEST_HOME/_tags_cache.json")" = "$before_2" ]
  [ "$(jq -c '."sample_3.ml"' "$TEST_HOME/_tags_cache.json")" = "$before_3" ]
}

@test "unsupported file: recorded as unsupported, never retried while unchanged" {
  make_repo
  mkdir -p "$REPO"
  printf 'no grammar for this\n' > "$REPO/sample.unknownext"
  h="$(git -C "$REPO" hash-object "$REPO/sample.unknownext")"
  printf 'sample.unknownext\t%s\n' "$h" > "$TEST_HOME/paths.tsv"
  # No registry entry for "unknownext" -- synapse-tags.sh exits 2 (needs
  # discovery), which this cache treats the same as exit 1: unsupported.

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ "$(jq -r '."sample.unknownext".unsupported' "$TEST_HOME/_tags_cache.json")" = "true" ]
  [ "$(jq -r '."sample.unknownext".tags' "$TEST_HOME/_tags_cache.json")" = "" ]

  : > "$FAKE_TS_LOG"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "a file that parsed to no tags is NOT recorded as unsupported" {
  # The distinction the batched form rests on, and the one it could most easily
  # lose: an unparseable file is absent from the batch output entirely, while a
  # file that parsed and simply had nothing in it still gets its path line.
  # Conflating them would make `synapse-query.sh symbol` report a perfectly
  # readable file as "not checked", and re-tag it on every single call.
  make_repo
  mkdir -p "$REPO"
  printf 'notags\n' > "$REPO/empty.ml"
  printf 'let x = 1\n' > "$REPO/full.ml"
  printf 'no grammar for this\n' > "$REPO/other.unknownext"
  for f in empty.ml full.ml other.unknownext; do
    printf '%s\t%s\n' "$f" "$(git -C "$REPO" hash-object "$f")" >> "$TEST_HOME/paths.tsv"
  done

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  [ "$(jq -r '."empty.ml".unsupported' "$TEST_HOME/_tags_cache.json")" = "false" ]
  [ "$(jq -r '."empty.ml".tags' "$TEST_HOME/_tags_cache.json")" = "" ]
  [[ "$(jq -r '."full.ml".tags' "$TEST_HOME/_tags_cache.json")" == *"FAKE_NAME"* ]]
  [ "$(jq -r '."other.unknownext".unsupported' "$TEST_HOME/_tags_cache.json")" = "true" ]

  # And all three are current: none is re-attempted.
  : > "$FAKE_TS_LOG"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "tags are attributed to the right file within one batch" {
  # Batch output is one flat stream for many files, so misattribution is the
  # new failure mode: every path's tags must be its own, not the previous
  # path's or the whole batch's.
  make_repo
  mkdir -p "$REPO"
  printf 'symbol:AlphaOnly\n' > "$REPO/a.ml"
  printf 'symbol:BetaOnly\n'  > "$REPO/b.ml"
  printf 'notags\n'           > "$REPO/c.ml"
  for f in a.ml b.ml c.ml; do
    printf '%s\t%s\n' "$f" "$(git -C "$REPO" hash-object "$f")" >> "$TEST_HOME/paths.tsv"
  done

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^tags ' "$FAKE_TS_LOG")" -eq 1 ]

  [[ "$(jq -r '."a.ml".tags' "$TEST_HOME/_tags_cache.json")" == *"AlphaOnly"* ]]
  [[ "$(jq -r '."a.ml".tags' "$TEST_HOME/_tags_cache.json")" != *"BetaOnly"* ]]
  [[ "$(jq -r '."b.ml".tags' "$TEST_HOME/_tags_cache.json")" == *"BetaOnly"* ]]
  [[ "$(jq -r '."b.ml".tags' "$TEST_HOME/_tags_cache.json")" != *"AlphaOnly"* ]]
  [ "$(jq -r '."c.ml".tags' "$TEST_HOME/_tags_cache.json")" = "" ]
  # No trailing newline, matching what the per-file form recorded.
  [ "$(jq -r '."a.ml".tags' "$TEST_HOME/_tags_cache.json" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "cached tag lines carry no batch indent, so field 1 is still the symbol" {
  # Batch output indents every tag line under its path; single-file output does
  # not. Consumers split on \t and read field 1 as the symbol name, so leaving
  # the indent makes field 1 empty on every line and `synapse-query.sh symbol`
  # matches nothing -- reporting a clean not-found for a file it did read.
  # Asserted here rather than only through that downstream symptom, because the
  # symptom looks like a query bug and this is where it would originate.
  make_repo
  mkdir -p "$REPO"
  printf 'symbol:AlphaOnly\n' > "$REPO/a.ml"
  printf 'a.ml\t%s\n' "$(git -C "$REPO" hash-object a.ml)" > "$TEST_HOME/paths.tsv"

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  run jq -r '.[].tags' "$TEST_HOME/_tags_cache.json"
  [ "$(grep -c '^	' <<< "$output")" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "AlphaOnly"' <<< "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "several files needing tagging at once: every one ends up correctly cached" {
  make_repo
  write_sample_files 6

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  n="$(jq 'keys | length' "$TEST_HOME/_tags_cache.json")"
  [ "$n" -eq 6 ]
  for i in 1 2 3 4 5 6; do
    [[ "$(jq -r --arg k "sample_$i.ml" '.[$k].tags' "$TEST_HOME/_tags_cache.json")" == *"FAKE_NAME"* ]]
  done
}

@test "path containing a space: cached correctly, no stray result file" {
  # Regression: the parallel step used `xargs -L 1` with three positional
  # args, and xargs word-splits on spaces as well as tabs -- so this path
  # shifted every field, tagged the wrong file, and wrote its result outside
  # $WORK/results (where the merge never saw it). The entry silently never
  # entered the cache and was re-attempted on every subsequent call.
  make_repo
  mkdir -p "$REPO/src/some dir"
  printf 'let spaced = 1\n' > "$REPO/src/some dir/spaced.ml"
  printf 'let plain = 2\n' > "$REPO/plain.ml"
  h_spaced="$(git -C "$REPO" hash-object "src/some dir/spaced.ml")"
  h_plain="$(git -C "$REPO" hash-object "plain.ml")"
  printf 'src/some dir/spaced.ml\t%s\nplain.ml\t%s\n' "$h_spaced" "$h_plain" > "$TEST_HOME/paths.tsv"

  cd "$TEST_HOME"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  [ "$(jq 'keys | length' "$TEST_HOME/_tags_cache.json")" -eq 2 ]
  [[ "$(jq -r '."src/some dir/spaced.ml".tags' "$TEST_HOME/_tags_cache.json")" == *"FAKE_NAME"* ]]
  [ "$(jq -r '."src/some dir/spaced.ml".hash' "$TEST_HOME/_tags_cache.json")" = "$h_spaced" ]
  [ "$(jq -r '."src/some dir/spaced.ml".unsupported' "$TEST_HOME/_tags_cache.json")" = "false" ]
  # The stray-file symptom: a result written to a name derived from a shifted
  # field lands in the caller's cwd instead of the work dir.
  [ ! -e "$TEST_HOME/$h_spaced" ]

  # And it is genuinely current -- not re-tagged on the next run.
  : > "$FAKE_TS_LOG"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "missing arguments: usage error, exit 1" {
  run run_cache --repo-root "$REPO"
  [ "$status" -eq 1 ]
}

@test "nonexistent paths file: exit 1" {
  make_repo
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/does-not-exist.tsv"
  [ "$status" -eq 1 ]
}

@test "empty paths file: nothing to do, exit 0, cache created but empty" {
  make_repo
  : > "$TEST_HOME/paths.tsv"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.json" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
}
