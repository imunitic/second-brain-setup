#!/usr/bin/env bats
# Tests claude/bin/synapse-write-node.sh -- the writer that keeps a node's
# exhaustive `sources` out of a context window in both directions.
#
# The Obsidian Local REST API is stubbed by tests/fixtures/fake-bin/curl, which
# writes PUT payloads as real files under $FAKE_CURL_VAULT_DIR, so these tests
# assert on the actual bytes the vault would receive.
#
# `sources_digest` is recomputed independently in python rather than by reusing
# the script's own formula. That matters more here than anywhere else in the
# system: the writer, /synapse-init's spec and synapse-query.sh's `stale` each
# implement the same digest definition, and if the test agreed with the writer by
# construction, a drift that makes every node report a false mismatch would pass.

load 'test_helper'

WRITER="$REPO_ROOT/claude/bin/synapse-write-node.sh"
QUERY="$REPO_ROOT/claude/bin/synapse-query.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  BODY="$TEST_HOME/body.md"
  PATHS="$TEST_HOME/paths.txt"
  printf '## Summary\nA node.\n\n## Links\n- part_of [[Other]]\n' > "$BODY"
}

teardown() {
  common_teardown
}

# The script resolves the repo from $PWD, so run it from inside $REPO. A --summary is
# supplied by default so the tests that are not about summaries stay readable;
# $SUMMARY overrides it and run_writer_raw skips it entirely.
run_write() {
  run_writer_raw --summary "${SUMMARY:-A one-line summary.}" "$@"
}

run_writer_raw() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_PUT_STATUS="${PUT_STATUS:-200}" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$WRITER" "$@"
}

run_query() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$QUERY" "$@"
}

node_file() { echo "$VAULT/synapse/$(repo_name)/$1.md"; }

# sha256 over the LC_ALL=C sorted "path:hash" lines, newline-joined, no trailing
# newline -- computed independently of the script under test.
expected_digest() {
  python3 - "$REPO" "$@" <<'PY'
import hashlib, subprocess, sys
repo, paths = sys.argv[1], sorted(set(sys.argv[2:]))
hs = subprocess.run(["git", "-C", repo, "hash-object"] + paths,
                    capture_output=True, text=True).stdout.split()
lines = sorted(f"{p}:{h}" for p, h in zip(paths, hs))
print(hashlib.sha256("\n".join(lines).encode()).hexdigest())
PY
}

# A repo with files at three shapes that the `## Sources` module rule treats
# differently: under a module's src/, under a top-level dir, and at the root.
make_layered_repo() {
  make_repo "${1:-}"
  mkdir -p "$REPO/mod-a/src/main/java/com/example" "$REPO/mod-b/src/main/java" "$REPO/docs"
  printf 'class A {}\n' > "$REPO/mod-a/src/main/java/com/example/A.java"
  printf 'class B {}\n' > "$REPO/mod-a/src/main/java/com/example/B.java"
  printf 'class C {}\n' > "$REPO/mod-b/src/main/java/C.java"
  printf '# doc\n' > "$REPO/docs/guide.md"
  printf 'root\n' > "$REPO/rootfile.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m layered
}

@test "writes frontmatter, fenced body and an empty ## Notes section" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Widget core" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  local f; f="$(node_file "Widget core")"
  [ -f "$f" ]
  grep -q '^title: "Widget core"$' "$f"
  grep -q '^node_type: synapse-node$' "$f"
  grep -q "^project: $(repo_name)\$" "$f"
  grep -q '^stale: false$' "$f"
  grep -qE '^built_at: "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}"$' "$f"
  grep -q '^<!-- synapse:generated:start -->$' "$f"
  grep -q '^<!-- synapse:generated:end -->$' "$f"
  grep -q '^## Notes$' "$f"
  # ## Notes must sit outside the generated region -- that placement is what makes
  # "human-authored, preserved verbatim" enforceable rather than a promise.
  [ "$(grep -n '^## Notes$' "$f" | cut -d: -f1)" -gt "$(grep -n 'synapse:generated:end' "$f" | cut -d: -f1)" ]
}

@test "a rebuild preserves human-authored ## Notes instead of resetting them" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"
  run run_write --title "Kept" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  # A human writes under the ## Notes heading the first build created -- that text
  # is outside the generated fence, which the design guarantees is "preserved
  # verbatim forever after".
  local f; f="$(node_file Kept)"
  printf 'Hand-written: the timer id is nullable on legacy rows.\n' >> "$f"
  grep -q 'Hand-written' "$f"

  printf '## Summary\nRewritten body.\n' > "$BODY"
  run run_write --title "Kept" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  # The generated region is replaced...
  grep -q 'Rewritten body\.' "$f"
  ! grep -q 'A node\.' "$f"
  # ...and everything after the closing fence survives. A blind PUT here would
  # silently destroy the human's notes, which is the one failure the fencing
  # scheme exists to prevent.
  grep -q 'Hand-written: the timer id is nullable on legacy rows\.' "$f"
  # Exactly one ## Notes heading -- the tail is re-emitted, not appended to a fresh one.
  [ "$(grep -c '^## Notes$' "$f")" -eq 1 ]
}

@test "the summary is stored as a frontmatter field on the node itself" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  SUMMARY='The claims core, called costs in code.' run run_write \
    --title "Summarised" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  # One copy, on the node. A separate summaries file would let the index describe a
  # node as it used to be with nothing able to detect the drift.
  grep -q '^summary: "The claims core, called costs in code\."$' "$(node_file Summarised)"
}

@test "a summary containing quotes and backslashes stays valid YAML" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  SUMMARY='Handles "quoted" input and a C:\path.' run run_write \
    --title "Escaped" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  # Escaped for a double-quoted YAML scalar: backslash first, then quote, or the
  # escaping escapes itself. Double-quoted rather than single because that is the
  # form synapse-query.sh's `field` subcommand already strips.
  grep -q '^summary: "Handles \\"quoted\\" input and a C:\\\\path\."$' "$(node_file Escaped)"
}

@test "a missing --summary is a usage error, not a node without one" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_writer_raw --title "Nosummary" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 2 ]
  [ ! -f "$(node_file Nosummary)" ]
}

@test "records HEAD as the baseline commit, in full" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Baselined" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  grep -q "^commit: $head\$" "$(node_file Baselined)"
  # Full, never abbreviated: git picks 12 characters on a large repo and lengthens
  # as history grows, so a stored short prefix is a collision waiting to happen.
  [ "${#head}" -eq 40 ]
  ! grep -qE '^commit: [0-9a-f]{1,39}$' "$(node_file Baselined)"
}

@test "the commit field is omitted when HEAD does not resolve yet" {
  # Files staged, nothing committed: `git ls-files` and `git hash-object` both work,
  # but there is no commit to record. Omitted rather than left empty, so a drift
  # check reads a missing baseline the same as an unusable one.
  REPO="$TEST_HOME/fresh"
  mkdir -p "$REPO/src"
  git init -q "$REPO"
  printf 'let x = 1\n' > "$REPO/src/foo.ml"
  git -C "$REPO" add src/foo.ml
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Uncommitted" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  ! grep -q '^commit:' "$(node_file Uncommitted)"
  # The rest of the node must still be complete.
  grep -q '^sources_digest: ' "$(node_file Uncommitted)"
}

@test "uncommitted changes in this node's own sources are called out" {
  make_layered_repo
  printf 'mod-a/src/main/java/com/example/A.java\n' > "$PATHS"
  printf 'class A { int changed; }\n' > "$REPO/mod-a/src/main/java/com/example/A.java"

  run run_write --title "Dirty" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  # git hash-object fingerprints the worktree, so the recorded commit is "what was
  # checked out" rather than a faithful baseline -- worth saying, since a later diff
  # would otherwise compare against content that was never committed.
  [[ "$output" == *"uncommitted changes in this node's sources"* ]]
  [[ "$output" == *"A.java"* ]]
}

@test "a dirty file outside the node's sources stays quiet" {
  make_layered_repo
  printf 'docs/guide.md\n' > "$PATHS"
  printf 'class A { int changed; }\n' > "$REPO/mod-a/src/main/java/com/example/A.java"

  run run_write --title "Quiet" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  # Narrow on purpose: a developer mid-work elsewhere in the repo should not be
  # warned on every node write.
  [[ "$output" != *"uncommitted changes"* ]]
}

@test "writing a node from its own recovered body is idempotent" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"
  printf '## Summary\nThe prose.\n\n## Crux\n```ocaml\nlet x = 1\n```\n' > "$BODY"
  run run_write --title "Roundtrip" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  # A reseat recovers the body from the node, drops the regenerated ## Sources block
  # and writes it back. Doing that repeatedly must not accrete padding, since the
  # fenced region is emitted with blank lines around the body.
  local f; f="$(node_file Roundtrip)"
  local pass1 pass2 i
  for i in 1 2; do
    sed -n '/<!-- synapse:generated:start -->/,/<!-- synapse:generated:end -->/p' "$f" \
      | sed -e '1d' -e '$d' | awk '/^## Sources$/ { exit } { print }' > "$TEST_HOME/recovered.md"
    run run_write --title "Roundtrip" --paths "$PATHS" --body "$TEST_HOME/recovered.md"
    [ "$status" -eq 0 ]
    if [ "$i" -eq 1 ]; then pass1="$(cat "$f")"; else pass2="$(cat "$f")"; fi
  done
  # Identical but for built_at, which moves by design.
  [ "$(printf '%s\n' "$pass1" | grep -v '^built_at:')" = "$(printf '%s\n' "$pass2" | grep -v '^built_at:')" ]
}

@test "a first write creates an empty ## Notes section" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Fresh" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## Notes$' "$(node_file Fresh)")" -eq 1 ]
}

@test "body is reproduced verbatim between the fences" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"
  printf '## Summary\nLine one.\n\n## Crux\n```ocaml\nlet x = 1\n```\n' > "$BODY"

  run run_write --title "Verbatim" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  # Extract the region between the fences, minus the appended ## Sources block.
  run bash -c "sed -n '/synapse:generated:start/,/^## Sources\$/p' '$(node_file Verbatim)' | sed '1d;\$d'"
  [[ "$output" == *'```ocaml'* ]]
  [[ "$output" == *'let x = 1'* ]]
  [[ "$output" == *'## Summary'* ]]
}

@test "sources lists every path with its real git hash, not a sample" {
  make_layered_repo
  printf 'mod-a/src/main/java/com/example/A.java\nmod-a/src/main/java/com/example/B.java\nmod-b/src/main/java/C.java\ndocs/guide.md\nrootfile.txt\n' > "$PATHS"

  run run_write --title "Wide" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  local f; f="$(node_file Wide)"
  [ "$(grep -c '^  - path: ' "$f")" -eq 5 ]
  local p h
  while IFS= read -r p; do
    h="$(git -C "$REPO" hash-object "$p")"
    grep -q "^  - path: $p\$" "$f"
    grep -A1 "^  - path: $p\$" "$f" | grep -q "^    hash: $h\$"
  done < "$PATHS"
}

@test "sources_digest matches an independently computed sha256" {
  make_layered_repo
  printf 'mod-a/src/main/java/com/example/A.java\ndocs/guide.md\nrootfile.txt\n' > "$PATHS"

  run run_write --title "Digest" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  local want; want="$(expected_digest \
    mod-a/src/main/java/com/example/A.java docs/guide.md rootfile.txt)"
  grep -q "^sources_digest: $want\$" "$(node_file Digest)"
  # The digest is also echoed on stdout, so a caller can log it without re-reading.
  [[ "$output" == *"$want"* ]]
}

@test "digest is independent of input order and of duplicate lines" {
  make_layered_repo
  printf 'docs/guide.md\nrootfile.txt\nmod-a/src/main/java/com/example/A.java\n' > "$PATHS"
  run run_write --title "OrderA" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  printf 'rootfile.txt\nmod-a/src/main/java/com/example/A.java\ndocs/guide.md\nrootfile.txt\n' > "$PATHS"
  run run_write --title "OrderB" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  local a b
  a="$(grep '^sources_digest: ' "$(node_file OrderA)")"
  b="$(grep '^sources_digest: ' "$(node_file OrderB)")"
  [ "$a" = "$b" ]
  # The duplicate must not survive into sources either.
  [ "$(grep -c '^  - path: rootfile.txt$' "$(node_file OrderB)")" -eq 1 ]
}

@test "## Sources mirror groups exactly like synapse-query.sh sources --modules" {
  make_layered_repo "ssh://git@example.com/x/proj.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  printf 'mod-a/src/main/java/com/example/A.java\nmod-a/src/main/java/com/example/B.java\nmod-b/src/main/java/C.java\ndocs/guide.md\nrootfile.txt\n' > "$PATHS"

  run run_write --title "Mirror" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]

  # The human mirror in the note...
  run bash -c "sed -n '/^## Sources\$/,/synapse:generated:end/p' '$(node_file Mirror)' \
      | grep '^- ' | sed -E 's/^- \`(.*)\` \(([0-9]+)\)\$/\1\t\2/'"
  local mirror="$output"

  # ...must agree with the query script's own --modules aggregation. Two
  # groupings for one concept is a divergence nobody notices for months.
  run run_query sources "Mirror" --modules
  [ "$status" -eq 0 ]
  [ "$mirror" = "$output" ]

  # And the rule itself: module = everything before /src/, else first component,
  # else "(repo root)".
  [[ "$mirror" == *"mod-a"* ]]
  [[ "$mirror" == *"mod-b"* ]]
  [[ "$mirror" == *"docs"* ]]
  [[ "$mirror" == *"(repo root)"* ]]
}

@test "a title needing sanitizing warns that inbound wikilinks will not resolve" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Bad — import/export" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"will not resolve"* ]]
  [ -f "$VAULT/synapse/$(repo_name)/Bad — import_export.md" ]
  # The title inside the note keeps the slash; only the filename is sanitized,
  # which is precisely why the link breaks and the warning has to exist.
  grep -q '^title: "Bad — import/export"$' "$VAULT/synapse/$(repo_name)/Bad — import_export.md"
}

@test "a clean title writes silently" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Bad — import and export" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
}

@test "refuses to write when the namespace records a different remote" {
  make_layered_repo "ssh://git@example.com/x/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/y/theirs.git"
  printf 'rootfile.txt\n' > "$PATHS"

  run run_write --title "Contaminant" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"belongs to a different repo"* ]]
  [[ "$output" == *"theirs.git"* ]]
  [[ "$output" == *"mine.git"* ]]
  # Nothing may be written into the other repo's namespace.
  [ ! -f "$(node_file Contaminant)" ]
}

@test "writes when the namespace remote matches" {
  make_layered_repo "ssh://git@example.com/x/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/x/mine.git"
  printf 'rootfile.txt\n' > "$PATHS"

  run run_write --title "Allowed" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [ -f "$(node_file Allowed)" ]
}

@test "writes when no Index.md exists yet, since that is a first-time build" {
  make_repo "ssh://git@example.com/x/fresh.git"
  printf 'src/foo.ml\n' > "$PATHS"
  [ ! -f "$VAULT/synapse/$(repo_name)/Index.md" ]

  run run_write --title "First" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [ -f "$(node_file First)" ]
}

@test "a remoteless repo compares by resolved repo root and is allowed" {
  make_repo
  write_synapse_index "$(repo_name)" "$(git -C "$REPO" rev-parse --show-toplevel)"
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Pathmatch" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [ -f "$(node_file Pathmatch)" ]
}

@test "a listed path that no longer exists fails loudly instead of writing a short node" {
  make_repo
  printf 'src/foo.ml\nsrc/deleted.ml\n' > "$PATHS"

  run run_write --title "Missing" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 1 ]
  # Must name the offender, not die with a raw `git hash-object` exit 128.
  [[ "$output" == *"not regular files"* ]]
  [[ "$output" == *"src/deleted.ml"* ]]
  [ ! -f "$(node_file Missing)" ]
}

@test "a directory in the path list fails, the way a submodule gitlink would" {
  make_layered_repo
  # git ls-files reports a submodule as one entry, but it is a directory on disk
  # and git hash-object fails on it, taking the whole batch down. Enumeration is
  # supposed to drop those; this asserts the writer still refuses rather than
  # silently emitting a node with fewer hashes than paths.
  printf 'rootfile.txt\ndocs\n' > "$PATHS"

  run run_write --title "Gitlink" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not regular files"* ]]
  [[ "$output" == *"submodule gitlink"* ]]
  [ ! -f "$(node_file Gitlink)" ]
}

@test "a non-2xx PUT is reported as a failure and stores nothing" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  PUT_STATUS=500 run run_write --title "Rejected" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PUT failed (500)"* ]]
  [ ! -f "$(node_file Rejected)" ]
}

@test "missing arguments exit 2, and an empty path list exits 1" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "T" --paths "$PATHS"
  [ "$status" -eq 2 ]

  run run_write --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 2 ]

  : > "$PATHS"
  run run_write --title "T" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty path list"* ]]
}

@test "runs outside a git repo exit 1 rather than inventing a namespace" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"
  mkdir -p "$TEST_HOME/notarepo"

  run env PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$TEST_HOME/notarepo" \
    "$WRITER" --title "Nope" --summary "S." --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repo"* ]]
}
