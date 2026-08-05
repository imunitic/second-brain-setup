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
  # Explicit template for the same reason the shipped scripts use one: macOS
  # `mktemp -d` with no template ignores TMPDIR, so the suite could not run at
  # all anywhere the system temp dir is not writable.
  TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/synapse-test.XXXXXX")"
  VAULT="$TEST_HOME/vault"
  REPO="$TEST_HOME/repo"
  mkdir -p "$TEST_HOME/.claude" "$VAULT"

  # Captured before the swap. Only for tests that must reach a real, machine-wide
  # cache they cannot reasonably fake -- currently just puppeteer's Chromium, which
  # mermaid-cli needs and which lives under the real $HOME. Never a general escape
  # hatch: everything else belongs inside $TEST_HOME.
  export REAL_HOME="$HOME"

  export HOME="$TEST_HOME"
  export ORIGINAL_HOME_UNUSED=1 # documents that $HOME is intentionally swapped for the test

  # Stop git's repo discovery from ascending out of the scratch dir. Needed
  # because $TMPDIR is honoured above, and a TMPDIR that happens to live inside
  # a git repo (e.g. ~/.emacs.d/var/tmp) makes every scratch directory look like
  # part of that repo -- so a test asserting "this is not a git repo" passes or
  # fails depending on the machine. The ceiling is $TEST_HOME itself, which is
  # above $REPO, so discovery from inside the test repo still finds it first.
  export GIT_CEILING_DIRECTORIES="$TEST_HOME"

  cat > "$HOME/.claude/synapse.conf" <<EOF
OBSIDIAN_VAULT_DIR="$VAULT"
EOF

  # Seeded from the shipped template so tests exercise the real default
  # boilerplate list, not a hand-copied duplicate that could drift from it.
  cp "$REPO_ROOT/claude/synapse-module-boilerplate.conf.template" \
    "$HOME/.claude/synapse-module-boilerplate.conf"
}

# In-place sed that works on both BSD and GNU. `sed -i ''` is BSD-only (GNU reads
# the empty string as a filename) and `sed -i` with no arg is GNU-only, so the
# suite avoids -i altogether: edit to a temp file, then move it back.
sed_i() { # sed_i <expression> <file>
  local expr="$1" file="$2"
  sed -e "$expr" "$file" > "$file.sed_i" && mv "$file.sed_i" "$file"
}

# sha256 of stdin, portable across macOS (shasum) and Linux (sha256sum). The
# tests compute expected digests independently of the scripts under test, so they
# need their own copy of this rather than sourcing one -- a shared implementation
# would let a wrong formula agree with itself.
sha256_stdin() {
  if command -v shasum >/dev/null; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}

common_teardown() {
  [ -n "${TEST_HOME:-}" ] && [ -d "$TEST_HOME" ] && rm -rf "$TEST_HOME"
}

# Writes a minimal vault Index.md (the Synapse Vault index note itself, not
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
