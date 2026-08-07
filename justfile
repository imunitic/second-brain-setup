# Task runner for this repo. The recipes here mirror .github/workflows/tests.yml
# deliberately: the point is that "green locally" and "green in CI" cannot mean
# different things. If you change the gate, change it in both places.
#
#   just            list the recipes
#   just check      the full gate -- run this before committing
#   just test       the suite, parallel
#   just fix        regenerate whatever `check` verifies
#
# Note on comments below: `just --list` shows the comment line immediately above a
# recipe, so each one gets a single short line there and any longer explanation
# goes above a blank line, where the listing will not pick it up.

set shell := ["bash", "-uc"]

_default:
    @just --list --unsorted

# --jobs parallelises within each file as well as across them, which is where the
# win is: one file is a quarter of the suite, so across-files-only would leave it
# as the critical path. Measured on 12 cores: 2m37s against roughly 5m serial.
#
# The `parallel` guard is why this is a recipe rather than a README line. `bats
# --jobs` shells out to GNU parallel and, when it is missing, does not fail -- it
# silently runs serially and produces an identical-looking log. A silent 2x is
# exactly what nobody notices, so here it is an error.

# Run the suite in parallel; pass file paths to narrow it.
test *FILES:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v parallel >/dev/null; then
        echo "GNU parallel not on PATH -- 'bats --jobs' would silently run serially." >&2
        echo "  macOS: brew install parallel      Debian/Ubuntu: apt-get install parallel" >&2
        exit 1
    fi
    targets="{{ FILES }}"
    [ -n "$targets" ] || targets="tests/"
    bats --jobs "$(getconf _NPROCESSORS_ONLN)" $targets

# Run the suite serially, for unreadable parallel failures or a missing parallel.
test-serial *FILES:
    bats {{ if FILES == "" { "tests/" } else { FILES } }}

# THIS IS FOR THE INNER LOOP, NOT A SUBSTITUTE FOR `just check`. It runs the tests
# that name the files you give it, and coverage by grep is a lower bound: a test can
# exercise a script without ever spelling its path, through an installed copy that
# another script invokes. The integration files are therefore always included --
# pipeline, rebuild-scenario and setup name almost nothing and exercise almost
# everything. Commit behind `just check`, always.
#
# Groups are derived rather than listed on purpose. A hand-maintained group list is
# one more thing that silently stops matching reality, and the coupling here is dense
# enough to guarantee it: synapse-tags.sh alone is exercised by seven files.

# Run only the tests covering the given source files, plus the integration ones.
test-for +PATHS:
    #!/usr/bin/env bash
    set -euo pipefail
    always="tests/synapse-pipeline.bats tests/synapse-rebuild-scenario.bats tests/setup.bats"
    picked=""
    for p in {{ PATHS }}; do
        b="$(basename "$p")"
        # A test file given directly is itself the target.
        case "$p" in tests/*.bats) picked="$picked $p"; continue ;; esac
        hits="$(grep -l -- "$b" tests/*.bats 2>/dev/null || true)"
        [ -n "$hits" ] || echo "no test names '$b' -- relying on the integration files" >&2
        picked="$picked $hits"
    done
    files="$(printf '%s %s' "$picked" "$always" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
    echo "running: $(printf '%s' "$files" | wc -w | tr -d ' ') files" >&2
    just test $files

# Same, for whatever you have changed against the upstream branch.
test-changed:
    #!/usr/bin/env bash
    set -euo pipefail
    changed="$(git diff --name-only @{u}.. 2>/dev/null; git diff --name-only; git diff --name-only --cached)"
    changed="$(printf '%s' "$changed" | sort -u | grep -v '^$' || true)"
    if [ -z "$changed" ]; then echo "nothing changed"; exit 0; fi
    echo "changed:"; printf '  %s\n' $changed
    just test-for $changed

# Catches the class of typo that only surfaces when a rarely-taken branch runs --
# an unbalanced quote inside an awk program embedded in a heredoc, say.

# Parse-check every shipped script without executing it.
syntax:
    #!/usr/bin/env bash
    set -euo pipefail
    n=0
    for f in claude/bin/*.sh claude/hooks/*.sh docs/*.sh setup.sh setup-obsidian-mcp.sh; do
        [ -f "$f" ] || continue
        bash -n "$f"
        n=$((n + 1))
    done
    echo "syntax ok: $n scripts"

# Verify, never regenerate: a `check` that quietly fixes what it is checking
# cannot fail, and the point is to catch a script edit committed without the
# regeneration that follows from it.

# Verify docs/scripts.md and the rendered diagrams match their sources.
docs-check:
    ./docs/generate-scripts-reference.sh --check
    ./docs/generate-diagrams.sh --check

# Regenerate both generated artefacts; diagrams need mermaid-cli and its Chromium.
fix:
    ./docs/generate-scripts-reference.sh
    ./docs/generate-diagrams.sh

# The same three things CI runs, in the same order, plus a syntax pass CI gets for
# free by executing the scripts.

# The full gate -- run before every commit.
check: syntax test docs-check
    @echo "all green"

# Several scripts shell out to the *installed* copy rather than the repo one, so
# an unsynced ~/.claude means testing a mix of old and new.

# Install into ~/.claude the way a user would.
install:
    ./setup.sh

# Show what changed against the pushed branch.
diff:
    @git --no-pager diff --stat @{u}.. 2>/dev/null || git --no-pager diff --stat
