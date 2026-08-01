# Shared setup for bats tests in this directory. Loaded with:
#   load 'test_helper'
#
# Every test gets an isolated $HOME (so hooks/setup.sh never touch the
# real ~/.claude) plus a scratch git repo and a scratch "vault" directory
# standing in for the Obsidian vault. Nothing here touches real Obsidian,
# real git remotes, or the network.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_BIN="$REPO_ROOT/tests/fixtures/fake-bin"

common_setup() {
  TEST_HOME="$(mktemp -d)"
  VAULT="$TEST_HOME/vault"
  REPO="$TEST_HOME/repo"
  mkdir -p "$TEST_HOME/.claude" "$VAULT"

  export HOME="$TEST_HOME"
  export ORIGINAL_HOME_UNUSED=1 # documents that $HOME is intentionally swapped for the test

  cat > "$HOME/.claude/second-brain.conf" <<EOF
OBSIDIAN_VAULT_DIR="$VAULT"
EOF
}

common_teardown() {
  [ -n "${TEST_HOME:-}" ] && [ -d "$TEST_HOME" ] && rm -rf "$TEST_HOME"
}

# Writes a minimal vault Index.md (the second-brain index note itself, not
# a Synapse per-project index) -- just enough for the SessionStart hook to
# have something to inject.
write_vault_index() {
  cat > "$VAULT/Index.md" <<'EOF'
---
title: "Index"
---
# Index
Test index content.
EOF
}

# Creates a throwaway git repo at $REPO with one tracked file, and
# optionally a remote (local git config only -- never actually fetched
# from or pushed to).
make_repo() {
  local remote="${1:-}"
  mkdir -p "$REPO/src"
  git init -q "$REPO"
  printf 'let x = 1\n' > "$REPO/src/foo.ml"
  git -C "$REPO" add src/foo.ml
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
  if [ -n "$remote" ]; then
    git -C "$REPO" remote add origin "$remote"
  fi
}

repo_name() {
  basename "$REPO"
}

repo_remote_or_path() {
  # Falls back to the git-resolved repo root, not the raw $REPO variable --
  # git rev-parse --show-toplevel resolves symlinks (e.g. macOS /tmp ->
  # /private/tmp), and that's what both the hook and /synapse-init actually
  # compare against.
  git -C "$REPO" remote get-url origin 2>/dev/null || git -C "$REPO" rev-parse --show-toplevel
}

# Fakes just enough of the Obsidian Local REST API plugin's on-disk state
# for synapse-staleness.sh to get past its own existence checks: the
# plugin's data.json (apiKey + port) and a stand-in cert file. Actual HTTP
# calls are intercepted by tests/fixtures/fake-bin/curl (prepended onto
# PATH by run_staleness_hook below), so the port/key values themselves are
# never really dialed.
setup_fake_obsidian_plugin() {
  mkdir -p "$VAULT/.obsidian/plugins/obsidian-local-rest-api"
  cat > "$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json" <<'EOF'
{"apiKey": "test-api-key", "port": 27124}
EOF
  : > "$HOME/.claude/obsidian-local-rest-api-ca.pem"
}

# Writes a Synapse per-project Index.md with the given `remote` frontmatter
# value, matching the shape /synapse-init produces.
write_synapse_index() {
  local project="$1" remote="$2"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/Index.md" <<EOF
---
title: "$project — Synapse index"
node_type: synapse-index
project: $project
remote: "$remote"
built_at: "test"
---
# $project — Synapse index
EOF
}
