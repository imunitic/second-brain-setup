#!/usr/bin/env bats
# Tests claude/bin/synapse-query.sh. The `stale` subcommand is the Tier 2 batch
# staleness verification that used to live in synapse-verify.sh.
# The Obsidian Local REST API is stubbed by tests/fixtures/fake-bin/curl,
# which serves and writes real files under $FAKE_CURL_VAULT_DIR -- so these
# tests exercise the script's actual digest arithmetic against real git
# objects, not a mock of it.
#
# The expected digest is computed independently in python rather than by
# reusing the script's own formula, so a change to either implementation
# fails the test instead of silently agreeing with itself.

load 'test_helper'

QUERY="$REPO_ROOT/claude/bin/synapse-query.sh"

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  # For `symbol`: real tree-sitter is stubbed by fake-bin/tree-sitter (always
  # emits one deterministic FAKE_NAME tag line); synapse-tags-cache.sh and
  # synapse-tags.sh are installed like a real setup.sh would, since `symbol`
  # shells out to the *installed* copies, not the repo ones.
  GRAMMARS_DIR="$TEST_HOME/grammars"
  FAKE_TS_LOG="$TEST_HOME/ts.log"
  FAKE_GIT_LOG="$TEST_HOME/git.log"
  : > "$FAKE_TS_LOG"
  : > "$FAKE_GIT_LOG"
  printf '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
  mkdir -p "$HOME/.claude/bin"
  cp "$REPO_ROOT/claude/bin/synapse-tags.sh" "$HOME/.claude/bin/synapse-tags.sh"
  cp "$REPO_ROOT/claude/bin/synapse-tags-cache.sh" "$HOME/.claude/bin/synapse-tags-cache.sh"
  chmod +x "$HOME/.claude/bin/synapse-tags.sh" "$HOME/.claude/bin/synapse-tags-cache.sh"
}

teardown() {
  common_teardown
}

# The script resolves the repo from $PWD, so run it from inside $REPO.
run_query() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    FAKE_TS_LOG="$FAKE_TS_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$QUERY" "$@"
}

run_stale() { run_query stale; }

# sha256 over the LC_ALL=C sorted "path:hash" lines, newline-joined, no
# trailing newline -- computed independently of the script under test.
expected_digest() {
  python3 - "$REPO" "$@" <<'PY'
import hashlib, subprocess, sys
repo, paths = sys.argv[1], sys.argv[2:]
hs = subprocess.run(["git", "-C", repo, "hash-object"] + paths,
                    capture_output=True, text=True).stdout.split()
lines = sorted(f"{p}:{h}" for p, h in zip(paths, hs))
print(hashlib.sha256("\n".join(lines).encode()).hexdigest())
PY
}

# Writes a node covering the given repo-relative paths, with a digest that is
# correct by construction unless $FORCE_DIGEST is set.
write_node() {
  local node="$1"; shift
  local digest="${FORCE_DIGEST:-$(expected_digest "$@")}"
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    echo "---"
    echo "title: \"${node%.md}\""
    echo "node_type: synapse-node"
    echo "project: $(repo_name)"
    echo "sources:"
    local p h
    for p in "$@"; do
      h="$(git -C "$REPO" hash-object "$p")"
      echo "  - path: $p"
      echo "    hash: $h"
    done
    echo "sources_digest: \"$digest\""
    echo "stale: false"
    echo "built_at: \"2026-08-03 16:15\""
    echo "---"
    echo
    echo "# ${node%.md}"
  } > "$VAULT/synapse/$(repo_name)/$node"
}

write_node_index() {
  mkdir -p "$VAULT/synapse/$(repo_name)"
  printf '%s' "$1" > "$VAULT/synapse/$(repo_name)/_index.json"
}

@test "stale: node whose files are unchanged: reports nothing, exit 0" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stale: source file changed outside Claude Code: reports the node" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  # The case Tier 1 cannot see: an edit that never went through a hook.
  printf 'let x = 2 (* changed *)\n' > "$REPO/src/foo.ml"

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"Foo Node"* ]]
  [[ "$output" == *"content changed"* ]]
}

@test "stale: recorded source file deleted: reports it by name" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  rm "$REPO/src/foo.ml"

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"source files gone: src/foo.ml"* ]]
}

@test "stale: multi-file node: order in sources does not affect the digest" {
  make_repo
  printf 'let y = 1\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m bar

  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # written in reverse order; the digest sorts, so it must still verify
  write_node "Foo Node.md" "src/foo.ml" "src/bar.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"src/bar.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stale: node with a wrong stored digest: reported as changed" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  FORCE_DIGEST="0000000000000000000000000000000000000000000000000000000000000000" \
    write_node "Foo Node.md" "src/foo.ml"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"content changed"* ]]
}

@test "stale: node built before sources_digest existed: reported, not silently passed" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Foo Node.md" "src/foo.ml"
  # strip the digest, simulating a namespace built under the old format
  grep -v '^sources_digest:' "$VAULT/synapse/$(repo_name)/Foo Node.md" > "$TEST_HOME/tmp" \
    && mv "$TEST_HOME/tmp" "$VAULT/synapse/$(repo_name)/Foo Node.md"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sources_digest"* ]]
}

@test "stale: node in _index.json but missing from the vault: reported" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node_index '{"src/foo.ml":["Ghost Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"node file missing"* ]]
}

@test "stale: namespace belongs to a different remote: exits 1, reports nothing" {
  make_repo "ssh://git@example.com/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  write_node_index '{"src/foo.ml":["Foo Node.md"],"_unassigned":[]}'

  run run_stale
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "stale: no namespace for this repo: exits 1, reports nothing" {
  make_repo
  run run_stale
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "stale: not inside a git repo: exits 1" {
  mkdir -p "$TEST_HOME/plain"
  run bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_CURL_LOG="$3" FAKE_CURL_VAULT_DIR="$4" bash "$5" stale' \
    _ "$TEST_HOME/plain" "$FAKE_BIN" "$CURL_LOG" "$VAULT" "$QUERY"
  [ "$status" -eq 1 ]
}

# --- body / sources / field ------------------------------------------------
# The point of these subcommands is that they read the expensive parts
# internally and print only a projection, so the assertions are mostly about
# what is *absent* from the output.

# A node with a generated fence, real hashes, and Notes content that must never
# leak into `body`.
write_fenced_node() {
  local node="$1"; shift
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    echo "---"
    echo "title: \"${node%.md}\""
    echo "node_type: synapse-node"
    echo "project: $(repo_name)"
    echo "sources:"
    local p
    for p in "$@"; do
      echo "  - path: $p"
      echo "    hash: $(git -C "$REPO" hash-object "$p")"
    done
    echo "sources_digest: \"$(expected_digest "$@")\""
    echo "stale: false"
    echo "built_at: \"2026-08-03 16:15\""
    echo "---"
    echo
    echo "# ${node%.md}"
    echo "<!-- synapse:generated:start -->"
    echo
    echo "## Summary"
    echo "Prose that should be printed."
    echo
    echo "## Sources"
    echo "- \`src\` (${#@})"
    echo "<!-- synapse:generated:end -->"
    echo
    echo "## Notes"
    echo "HUMAN NOTES must never appear in body output."
  } > "$VAULT/synapse/$(repo_name)/$node"
}

@test "body: prints the fenced prose only, excluding frontmatter and Notes" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query body "Foo Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prose that should be printed."* ]]
  [[ "$output" != *"path:"* ]]
  [[ "$output" != *"HUMAN NOTES"* ]]
  [[ "$output" != *"sources_digest"* ]]
  [[ "$output" != *"synapse:generated"* ]]
}

@test "body: accepts the node name with or without .md" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query body "Foo Node.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prose that should be printed."* ]]
}

@test "body: unfenced node falls back to post-frontmatter and warns on stderr" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_node "Old Node.md" "src/foo.ml"   # written without a fence

  run run_query body "Old Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no generated fence"* ]]
  [[ "$output" != *"path:"* ]]
}

@test "body: unknown node exits 1" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_query body "Nope"
  [ "$status" -eq 1 ]
}

@test "sources: --count matches the real number of paths" {
  make_repo
  printf 'let y = 1\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m bar
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "src/bar.ml"

  run run_query sources "Foo Node" --count
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "sources: bare form lists every path, --filter narrows it" {
  make_repo
  printf 'let y = 1\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m bar
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "src/bar.ml"

  run run_query sources "Foo Node"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]

  run run_query sources "Foo Node" --filter bar
  [ "$output" = "src/bar.ml" ]
}

@test "sources: --modules groups by module root with counts" {
  make_repo
  mkdir -p "$REPO/other/src/main/java"
  printf 'x\n' > "$REPO/other/src/main/java/A.java"
  git -C "$REPO" add other/src/main/java/A.java
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m other
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "other/src/main/java/A.java"

  run run_query sources "Foo Node" --modules
  [ "$status" -eq 0 ]
  # `other/src/main/java/A.java` is Maven boilerplate and groups as `other`;
  # `src/foo.ml` has src first so it is the repo root's own src -- grouped as
  # "src" per the module_of rule.
  [[ "$output" == *"other"$'\t'"1"* ]]
}

@test "sources: --modules keeps one segment past src/ for a non-boilerplate layout" {
  make_repo
  mkdir -p "$REPO/eon_engine/src/render" "$REPO/eon_engine/src/audio"
  printf 'x\n' > "$REPO/eon_engine/src/render/render_commands.ml"
  printf 'x\n' > "$REPO/eon_engine/src/audio/audio_system.ml"
  git -C "$REPO" add eon_engine
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m eon_engine
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" \
    "eon_engine/src/render/render_commands.ml" "eon_engine/src/audio/audio_system.ml"

  run run_query sources "Foo Node" --modules
  [ "$status" -eq 0 ]
  # Neither path is Maven boilerplate, so each keeps the segment right after
  # src/ instead of collapsing both into one indistinguishable "eon_engine".
  [[ "$output" == *"eon_engine/src/render"$'\t'"1"* ]]
  [[ "$output" == *"eon_engine/src/audio"$'\t'"1"* ]]
}

@test "sources: --modules boilerplate chains are read from config, not hardcoded" {
  make_repo
  mkdir -p "$REPO/mod-a/src/main/kotlin"
  printf 'x\n' > "$REPO/mod-a/src/main/kotlin/A.kt"
  git -C "$REPO" add mod-a
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m kotlin
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "mod-a/src/main/kotlin/A.kt"

  # Not in the shipped default list yet: falls through to the generic rule,
  # keeping one segment past src/ rather than collapsing to "mod-a".
  run run_query sources "Foo Node" --modules
  [ "$status" -eq 0 ]
  [[ "$output" == *"mod-a/src/main"$'\t'"1"* ]]

  # Add it to the config, same as a user would by hand -- now it collapses,
  # proving the chain list is genuinely read from disk each run.
  printf 'src/main/kotlin\n' >> "$HOME/.claude/synapse-module-boilerplate.conf"
  run run_query sources "Foo Node" --modules
  [ "$status" -eq 0 ]
  [[ "$output" == *"mod-a"$'\t'"1"* ]]
}

@test "field: returns unquoted scalars, empty for an absent key" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query field "Foo Node" stale
  [ "$output" = "false" ]

  run run_query field "Foo Node" built_at
  [ "$output" = "2026-08-03 16:15" ]     # quotes stripped

  run run_query field "Foo Node" nonexistent_key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "field: refuses 'sources' with exit 2 and points at the right subcommand" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query field "Foo Node" sources
  [ "$status" -eq 2 ]
  [[ "$output" == *"use: synapse-query.sh sources"* ]]
}

@test "unknown subcommand and no subcommand both exit 2" {
  make_repo
  run run_query bogus
  [ "$status" -eq 2 ]
  run run_query
  [ "$status" -eq 2 ]
}

# --- temp-dir handling -----------------------------------------------------

@test "an unusable TMPDIR is fatal rather than resolving every path against /" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  # This script runs without `set -e` on purpose -- its exit codes are answers,
  # not failures -- so a failed `mktemp -d` left $WORK empty and every path
  # under it resolving against `/`. Found by running the script for real outside
  # the suite, in a sandbox whose TMPDIR was not the system temp dir.
  run env TMPDIR="$TEST_HOME/definitely-not-here" \
    PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$QUERY" stale
  [ "$status" -ne 0 ]
}

@test "every mktemp in the shipped scripts passes an explicit template" {
  # macOS `mktemp`/`mktemp -d` ignore TMPDIR unless given a template, so a bare
  # call writes to the system temp dir whatever the caller asked for. Checked
  # statically because the resulting failure is environment-dependent: it passes
  # on Linux and on any macOS where the system temp dir happens to be writable.
  # Hooks as well as bin: the first version of this check globbed only claude/bin
  # and missed a bare mktemp in synapse-staleness.sh for exactly that reason.
  run grep -nE 'mktemp( -d)?[[:space:]]*(\)|\||$)' \
    "$REPO_ROOT"/claude/bin/*.sh "$REPO_ROOT"/claude/hooks/*.sh
  if [ "$status" -eq 0 ]; then
    echo "bare mktemp (no template) found:"
    echo "$output"
    false
  fi
}

@test "config: reads the pre-rename second-brain.conf when synapse.conf is absent" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  # A machine whose scripts were updated ahead of setup.sh: only the old name
  # exists. Without the fallback this reports "no vault" and every subcommand
  # exits 1, which reads as "the graph is fine" to a caller that treats exit 1
  # as absence rather than failure.
  mv "$HOME/.claude/synapse.conf" "$HOME/.claude/second-brain.conf"

  run run_query body "Foo Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prose that should be printed."* ]]
}

@test "config: synapse.conf wins when both names exist" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  # The old file points somewhere useless; if it were preferred, this fails.
  printf 'OBSIDIAN_VAULT_DIR="%s/nope"\n' "$TEST_HOME" > "$HOME/.claude/second-brain.conf"

  run run_query body "Foo Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prose that should be printed."* ]]
}

# --- symbol: exact-name def/ref lookup, backed by the tags cache -----------
# Real tree-sitter is stubbed (fake-bin/tree-sitter always emits one
# deterministic `FAKE_NAME` tag line), so these tests exercise `symbol`'s own
# control flow -- cache backfill, exact-name filtering, disable knob, and the
# distinct "not checked" reporting -- not tree-sitter's actual output.

@test "symbol: exact match across a node's sources, with file and tag line" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query symbol FAKE_NAME "Foo Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/foo.ml"* ]]
  [[ "$output" == *"FAKE_NAME"* ]]
}

@test "symbol: a name that never appears is silent, exit 0" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query symbol this_name_does_not_exist "Foo Node"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "symbol: second query against the same node re-tags nothing" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query symbol FAKE_NAME "Foo Node"
  [ "$status" -eq 0 ]
  : > "$FAKE_TS_LOG"

  run run_query symbol FAKE_NAME "Foo Node"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "symbol: disabled via env var -- no output, no tagging at all" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run env SYNAPSE_DISABLE_SYMBOL_CACHE=1 \
    PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" FAKE_TS_LOG="$FAKE_TS_LOG" FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$QUERY" symbol FAKE_NAME "Foo Node"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "symbol: missing arguments is a usage error, exit 2" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"

  run run_query symbol FAKE_NAME
  [ "$status" -eq 2 ]
}

@test "symbol: unknown node exits 1" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_query symbol FAKE_NAME "No Such Node"
  [ "$status" -eq 1 ]
}

@test "symbol: unsupported file is reported distinctly, never conflated with no-match" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # No registry entry for this extension at all -- synapse-tags.sh exits 2
  # (needs discovery), which the cache records as unsupported.
  printf 'no grammar for this\n' > "$REPO/src/foo.unknownext"
  git -C "$REPO" add src/foo.unknownext
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "add unsupported file"
  write_fenced_node "Foo Node.md" "src/foo.unknownext"

  run run_query symbol FAKE_NAME "Foo Node"
  [ "$status" -eq 0 ]
  # bats merges stderr into $output by default, so the "not checked" note
  # (stderr) is what's here -- no tab-separated hit line (stdout) at all,
  # since the file was never actually tagged.
  [[ "$output" == *"unsupported"* ]]
  [[ "$output" != *$'\t'"FAKE_NAME"* ]]
}

@test "symbol: a node with several sources returns hits from every one that matches" {
  make_repo
  printf 'let y = 2\n' > "$REPO/src/bar.ml"
  git -C "$REPO" add src/bar.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "add bar.ml"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml" "src/bar.ml"

  run run_query symbol FAKE_NAME "Foo Node"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/foo.ml"* ]]
  [[ "$output" == *"src/bar.ml"* ]]
}
