#!/usr/bin/env bats
# Tests claude/bin/synapse-build-lists.sh -- enumeration plus manifest expansion,
# the step that makes coverage a printed number instead of an assumption.
#
# No Obsidian involvement at all here: this script only reads git and writes files
# under $SYNAPSE_WORK_DIR, so nothing is stubbed.

load 'test_helper'

BUILD_LISTS="$REPO_ROOT/claude/bin/synapse-build-lists.sh"

setup() {
  common_setup
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
}

teardown() {
  common_teardown
}

# Runs from inside $REPO (the repo is resolved from $PWD) with an explicit work
# dir, which is the arrangement an installed copy in ~/.claude/bin always has.
run_build() {
  SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$BUILD_LISTS" "$@"
}

write_manifest() {
  printf '%b' "$1" > "$WORK/manifest.tsv"
}

make_mixed_repo() {
  make_repo
  mkdir -p "$REPO/mod-a/src/main/java" "$REPO/docs" "$REPO/assets"
  printf 'class A {}\n' > "$REPO/mod-a/src/main/java/A.java"
  printf 'class B {}\n' > "$REPO/mod-a/src/main/java/B.java"
  printf '# guide\n' > "$REPO/docs/guide.md"
  printf 'stray\n' > "$REPO/stray.txt"
  printf 'PNGDATA\n' > "$REPO/assets/logo.png"
  printf 'JARDATA\n' > "$REPO/assets/lib.jar"
  printf 'ignored\n' > "$REPO/.gitignore"
  printf 'secret.txt\n' > "$REPO/.gitignore"
  printf 'shh\n' > "$REPO/secret.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m mixed
}

@test "enumerates tracked files and drops binary extensions" {
  make_mixed_repo
  write_manifest 'Everything\t.\t\n'

  run run_build
  [ "$status" -eq 0 ]

  grep -q '^mod-a/src/main/java/A.java$' "$WORK/all.txt"
  grep -q '^docs/guide.md$' "$WORK/all.txt"
  # Binary/generated files have no prose value, so they are dropped at
  # enumeration rather than parked in _unassigned, where every future re-run
  # sweep would dutifully try to classify a favicon.
  ! grep -q 'logo.png' "$WORK/all.txt"
  ! grep -q 'lib.jar' "$WORK/all.txt"
}

@test "drops build artifacts from ecosystems other than the JVM" {
  make_repo
  # The invariant: an exclusion list that only knows one ecosystem's artifacts
  # silently indexes thousands of compiled files from every other as if they were
  # source, which is why the lists are grouped by what a file is.
  mkdir -p "$REPO/py" "$REPO/rust" "$REPO/ml" "$REPO/data" "$REPO/web"
  printf 'x\n' > "$REPO/py/mod.pyc"
  printf 'x\n' > "$REPO/py/dist.whl"
  printf 'x\n' > "$REPO/py/arr.npy"
  printf 'x\n' > "$REPO/rust/lib.rlib"
  printf 'x\n' > "$REPO/rust/obj.o"
  printf 'x\n' > "$REPO/ml/model.safetensors"
  printf 'x\n' > "$REPO/ml/weights.pt"
  printf 'x\n' > "$REPO/data/rows.parquet"
  printf 'x\n' > "$REPO/data/local.sqlite3"
  printf 'x\n' > "$REPO/web/clip.mp4"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m artifacts
  write_manifest 'Everything\t.\t\n'

  run run_build
  [ "$status" -eq 0 ]
  local dropped
  for dropped in mod.pyc dist.whl arr.npy lib.rlib obj.o model.safetensors weights.pt rows.parquet local.sqlite3 clip.mp4; do
    ! grep -q "$dropped" "$WORK/all.txt"
  done
}

@test "drops lockfiles and minified output, which extensions alone cannot catch" {
  make_repo
  mkdir -p "$REPO/js"
  printf '{}\n' > "$REPO/package-lock.json"
  printf 'x\n' > "$REPO/Cargo.lock"
  printf 'x\n' > "$REPO/go.sum"
  printf 'x\n' > "$REPO/poetry.lock"
  printf 'x\n' > "$REPO/js/bundle.min.js"
  printf 'x\n' > "$REPO/js/bundle.js.map"
  printf 'real source\n' > "$REPO/js/app.js"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m locks
  write_manifest 'Everything\t.\t\n'

  run run_build
  [ "$status" -eq 0 ]
  ! grep -q 'package-lock.json' "$WORK/all.txt"
  ! grep -q 'Cargo.lock' "$WORK/all.txt"
  ! grep -q 'go.sum' "$WORK/all.txt"
  ! grep -q 'poetry.lock' "$WORK/all.txt"
  ! grep -q 'bundle.min.js' "$WORK/all.txt"
  ! grep -q 'bundle.js.map' "$WORK/all.txt"
  # A hand-written .js must survive: the noise rule keys on the name, not the
  # extension, precisely so this stays indexed.
  grep -q '^js/app.js$' "$WORK/all.txt"
}

@test "source files of every language survive enumeration" {
  make_repo
  mkdir -p "$REPO/poly"
  local ext
  for ext in py rs go ts tsx rb ex exs kt swift c h cpp hpp cs php scala clj hs lua sh sql yaml toml md json csv svg ipynb; do
    printf 'source\n' > "$REPO/poly/file.$ext"
  done
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m poly
  write_manifest 'Everything\t.\t\n'

  run run_build
  [ "$status" -eq 0 ]
  # Guards the opposite failure from the two tests above: an over-broad exclusion
  # pattern quietly deleting a language's actual source from the graph.
  for ext in py rs go ts tsx rb ex exs kt swift c h cpp hpp cs php scala clj hs lua sh sql yaml toml md json csv svg ipynb; do
    grep -q "^poly/file.$ext\$" "$WORK/all.txt"
  done
}

@test "\$SYNAPSE_EXTRA_EXCLUDE_RE adds repo-specific noise without losing the defaults" {
  make_mixed_repo
  mkdir -p "$REPO/generated"
  printf 'gen\n' > "$REPO/generated/client.java"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m gen
  write_manifest 'Everything\t.\t\n'

  run env SYNAPSE_WORK_DIR="$WORK" SYNAPSE_EXTRA_EXCLUDE_RE='^generated/'     bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$BUILD_LISTS" --reenumerate
  [ "$status" -eq 0 ]
  ! grep -q 'generated/client.java' "$WORK/all.txt"
  # The built-in lists still apply.
  ! grep -q 'logo.png' "$WORK/all.txt"
  grep -q 'mod-a/src/main/java/A.java' "$WORK/all.txt"
}

@test "gitignored files never appear, since enumeration goes through git ls-files" {
  make_mixed_repo
  write_manifest 'Everything\t.\t\n'

  run run_build
  [ "$status" -eq 0 ]
  [ -f "$REPO/secret.txt" ]
  ! grep -q 'secret.txt' "$WORK/all.txt"
}

@test "skips a submodule gitlink, which git ls-files reports but git hash-object cannot hash" {
  make_repo
  git init -q "$TEST_HOME/sub"
  printf 'sub content\n' > "$TEST_HOME/sub/thing.txt"
  git -C "$TEST_HOME/sub" add -A
  git -C "$TEST_HOME/sub" -c user.email=t@t -c user.name=t commit -q -m init
  git -C "$REPO" -c protocol.file.allow=always submodule add -q "$TEST_HOME/sub" vendor/sub
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m addsub

  write_manifest 'Everything\t.\t\n'
  run run_build
  [ "$status" -eq 0 ]

  # `git ls-files` lists vendor/sub as a single entry...
  git -C "$REPO" ls-files | grep -q '^vendor/sub$'
  # ...but it is a directory on disk, and leaving it in takes down the whole
  # `git hash-object --stdin-paths` batch. The .gitmodules file itself is real
  # text and must survive.
  ! grep -q '^vendor/sub$' "$WORK/all.txt"
  grep -q '^.gitmodules$' "$WORK/all.txt"
}

@test "expands each manifest line into a numbered list plus its title" {
  make_mixed_repo
  write_manifest 'Code — the java\t^mod-a/\t\nDocs — the docs\t^docs/\t\n'

  run run_build
  [ "$status" -eq 0 ]

  [ "$(cat "$WORK/lists/01.title")" = "Code — the java" ]
  [ "$(cat "$WORK/lists/02.title")" = "Docs — the docs" ]
  [ "$(wc -l < "$WORK/lists/01.txt" | tr -d ' ')" -eq 2 ]
  [ "$(wc -l < "$WORK/lists/02.txt" | tr -d ' ')" -eq 1 ]
  # The per-node counts are echoed, so a bad regex is visible immediately.
  [[ "$output" == *"01	2	Code — the java"* ]]
}

@test "the exclude column removes paths the include column matched" {
  make_mixed_repo
  write_manifest 'Java except B\t^mod-a/\tB\\.java$\n'

  run run_build
  [ "$status" -eq 0 ]
  grep -q 'A.java' "$WORK/lists/01.txt"
  ! grep -q 'B.java' "$WORK/lists/01.txt"
}

@test "an empty exclude column excludes nothing" {
  make_mixed_repo
  # Third column absent entirely -- the script must not fall back to a pattern
  # that silently matches everything.
  printf 'Java\t^mod-a/\n' > "$WORK/manifest.tsv"

  run run_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORK/lists/01.txt" | tr -d ' ')" -eq 2 ]
}

@test "coverage reports the arithmetic and records what nothing claimed" {
  make_mixed_repo
  write_manifest 'Java\t^mod-a/\t\nDocs\t^docs/\t\n'

  run run_build
  [ "$status" -eq 0 ]

  local enumerated; enumerated="$(wc -l < "$WORK/all.txt" | tr -d ' ')"
  [[ "$output" == *"enumerated: $enumerated"* ]]
  [[ "$output" == *"covered:    3"* ]]
  # stray.txt, .gitignore and src/foo.ml are claimed by nothing.
  grep -q '^stray.txt$' "$WORK/unassigned.txt"
  grep -q '^src/foo.ml$' "$WORK/unassigned.txt"
  [ "$(wc -l < "$WORK/unassigned.txt" | tr -d ' ')" -eq "$((enumerated - 3))" ]
}

@test "a pattern that matches nothing yields an empty list rather than failing" {
  make_mixed_repo
  # The real slip this guards: `config$` looks like "the config directory" but
  # matches only a file literally named config.
  write_manifest 'Nothing\t^config$\t\n'

  run run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK/lists/01.txt" ]
  [ ! -s "$WORK/lists/01.txt" ]
  [[ "$output" == *"01	0	Nothing"* ]]
}

@test "an existing all.txt is reused, and --reenumerate rebuilds it" {
  make_mixed_repo
  write_manifest 'Everything\t.\t\n'
  run run_build
  [ "$status" -eq 0 ]

  printf 'sentinel-only\n' > "$WORK/all.txt"
  run run_build
  [ "$status" -eq 0 ]
  [[ "$output" != *"enumerating"* ]]
  [ "$(cat "$WORK/all.txt")" = "sentinel-only" ]

  run run_build --reenumerate
  [ "$status" -eq 0 ]
  [[ "$output" == *"enumerating"* ]]
  ! grep -q 'sentinel-only' "$WORK/all.txt"
}

@test "lists are rebuilt from scratch, so a removed manifest line leaves no stale list" {
  make_mixed_repo
  write_manifest 'Java\t^mod-a/\t\nDocs\t^docs/\t\n'
  run run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK/lists/02.txt" ]

  write_manifest 'Java\t^mod-a/\t\n'
  run run_build
  [ "$status" -eq 0 ]
  [ ! -f "$WORK/lists/02.txt" ]
}

@test "work dir comes from \$SYNAPSE_WORK_DIR, not from the script's own location" {
  make_mixed_repo
  write_manifest 'Java\t^mod-a/\t\n'

  # The invariant: an installed script must never derive its work dir from
  # ${BASH_SOURCE[0]}. That only works while the script sits next to its data, and
  # breaks silently once it lives in ~/.claude/bin.
  run run_build
  [ "$status" -eq 0 ]
  [ -f "$WORK/lists/01.txt" ]
  [ ! -e "$(dirname "$BUILD_LISTS")/lists" ]
  [ ! -e "$(dirname "$BUILD_LISTS")/all.txt" ]
}

@test "with \$SYNAPSE_WORK_DIR unset it works out of ~/.claude and never writes into the repo" {
  make_mixed_repo
  # These scripts resolve the repo from $PWD, so they always run from inside it. A
  # $PWD default would therefore drop all.txt (megabytes on a large repo), lists/,
  # the manifest and the coverage files into the user's checkout.
  local default_work="$HOME/.claude/synapse-work/$(repo_name)"
  mkdir -p "$default_work"
  printf 'Java\t^mod-a/\n' > "$default_work/manifest.tsv"

  run bash -c 'cd "$1" && shift && unset SYNAPSE_WORK_DIR && bash "$@"' _ "$REPO" "$BUILD_LISTS"
  [ "$status" -eq 0 ]
  [ -f "$default_work/lists/01.txt" ]
  [ -f "$default_work/all.txt" ]

  # Nothing may appear in the repo. $HOME is swapped per test, so this asserts the
  # documented default path, not merely that some other directory was used.
  [ ! -e "$REPO/lists" ]
  [ ! -e "$REPO/all.txt" ]
  [ ! -e "$REPO/unassigned.txt" ]
  [ ! -e "$REPO/covered.txt" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

@test "the default work dir is created on demand" {
  make_mixed_repo
  local default_work="$HOME/.claude/synapse-work/$(repo_name)"
  [ ! -d "$default_work" ]

  # No manifest yet, so this fails -- but it must fail on the missing manifest,
  # having created the directory, rather than on the directory not existing.
  run bash -c 'cd "$1" && shift && unset SYNAPSE_WORK_DIR && bash "$@"' _ "$REPO" "$BUILD_LISTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no manifest.tsv"* ]]
  [ -d "$default_work" ]
}

@test "a missing manifest and a non-repo directory both exit 1" {
  make_mixed_repo

  run run_build
  [ "$status" -eq 1 ]
  [[ "$output" == *"no manifest.tsv"* ]]

  write_manifest 'Java\t^mod-a/\t\n'
  mkdir -p "$TEST_HOME/notarepo"
  run env SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$TEST_HOME/notarepo" "$BUILD_LISTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repo"* ]]
}

@test "an unknown flag exits 2" {
  make_mixed_repo
  write_manifest 'Java\t^mod-a/\t\n'

  run run_build --nope
  [ "$status" -eq 2 ]
}
