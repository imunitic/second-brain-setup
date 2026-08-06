#!/bin/bash
# Prints `tree-sitter tags` output (definitions + name-based call references),
# cloning/registering each language's grammar on first use. Deliberately
# dumb/mechanical -- no reasoning here. See docs/synapse-graph.md's "Optional
# tree-sitter acceleration" section and `synapse-grammars.conf`'s own header.
#
# Usage: synapse-tags.sh <file-path>
#        synapse-tags.sh --paths <file-list>
#   Grammar cache dir: $SYNAPSE_GRAMMARS_DIR, default ~/.cache/synapse/grammars/.
#
# `--paths` tags every listed file in ONE tree-sitter invocation. That is not a
# convenience: CLI startup and grammar load dominate the per-file cost, and 200
# Java files measured 0.076s batched against 2.543s as 200 invocations across 12
# workers -- 33x, single-threaded against parallel. At 20,000 files a single
# invocation runs ~17.5s, so per-file work is real; startup simply swamped it at
# any size below a few thousand. Anything walking a whole repository should use
# this form.
#
# Output is attributable in both forms: an unindented line is a path, and the
# tab-indented lines under it are that path's tags.
#
# A mixed-extension list is fine and is why batch mode passes no `--scope`:
# tree-sitter infers the language per file from its extension, whereas forcing a
# scope makes it parse every file as that language (verified -- a `.gradle` file
# in a Java-scoped batch is parsed as Java). Single-file mode keeps `--scope`,
# which is exact and preserves its existing behaviour.
#
# Extensions with no usable grammar are reported once each on stderr and skipped;
# tree-sitter's own warning is eight lines per FILE, which is unreadable at repo
# scale. One line per extension is all a caller can act on.
#
# Exit codes (every caller must fail soft on any non-zero and fall back to
# reading the file directly -- this is never a hard dependency):
#   0 - tags printed to stdout. In `--paths` mode this is the outcome whenever
#       the batch ran, even if some extensions had no grammar: a mixed repo
#       nearly always has some, and failing the batch for them would throw away
#       every language that did work.
#   1 - not usable right now (missing tree-sitter/jq/C compiler, no
#       extension, a registry entry marked `unsupported: true`, or a clone/
#       registration failure) -- nothing else to try
#   2 - extension has no registry entry at all -- the caller (a Claude
#       procedure, e.g. /synapse-init) should run grammar discovery and
#       retry, not treat this the same as a hard failure.
#       Single-file mode only: a batch spanning many extensions has no single
#       answer, so it warns per extension and returns 0.
set -uo pipefail

MODE="single"
FILE=""
PATHS_FILE=""
case "${1:-}" in
  --paths) MODE="batch"; PATHS_FILE="${2:-}"; [ -n "$PATHS_FILE" ] && [ -f "$PATHS_FILE" ] || exit 1 ;;
  "")      exit 1 ;;
  *)       FILE="$1"; [ -f "$FILE" ] || exit 1 ;;
esac

command -v tree-sitter >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || exit 1

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
GRAMMARS_DIR="${SYNAPSE_GRAMMARS_DIR:-$HOME/.cache/synapse/grammars}"
REGISTRY="$HOME/.claude/synapse-grammars.conf"
[ -f "$REGISTRY" ] || printf '{}' > "$REGISTRY"

TS_CONFIG="$HOME/.config/tree-sitter/config.json"
REPOS_PARENT="$GRAMMARS_DIR/repos"

# Makes a grammar usable for one extension, echoing its scope on success. Shared
# by both modes so the registry lookup, clone and parser-directory registration
# cannot drift between them.
#   0 - ready; scope echoed on stdout
#   1 - unusable (marked unsupported, malformed entry, clone or config failure)
#   2 - no registry entry for this extension
ensure_grammar() { # ensure_grammar <ext>
  local ext="$1" entry unsupported repo scope repo_name repo_dir already tmp
  entry="$(jq -r --arg ext "$ext" '.[$ext] // empty' "$REGISTRY" 2>/dev/null)"
  [ -n "$entry" ] || return 2

  unsupported="$(printf '%s' "$entry" | jq -r '.unsupported // false' 2>/dev/null)"
  [ "$unsupported" != "true" ] || return 1

  repo="$(printf '%s' "$entry" | jq -r '.repo // empty' 2>/dev/null)"
  scope="$(printf '%s' "$entry" | jq -r '.scope // empty' 2>/dev/null)"
  [ -n "$repo" ] && [ -n "$scope" ] || return 1

  repo_name="$(basename "$repo" .git)"
  repo_dir="$REPOS_PARENT/$repo_name"
  mkdir -p "$REPOS_PARENT"
  if [ ! -d "$repo_dir" ]; then
    git clone --depth 1 -q "$repo" "$repo_dir" >/dev/null 2>&1 || { rm -rf "$repo_dir"; return 1; }
  fi

  [ -f "$TS_CONFIG" ] || tree-sitter init-config >/dev/null 2>&1
  [ -f "$TS_CONFIG" ] || return 1

  # tree-sitter scans each parser-directories entry for grammar repos living
  # *inside* it -- registering the repo dir itself (rather than its parent)
  # leaves --scope resolution failing with "Unknown scope", confirmed by
  # testing directly against a real grammar.
  already="$(jq -r --arg d "$REPOS_PARENT" '(."parser-directories" // []) | index($d) != null' "$TS_CONFIG" 2>/dev/null)"
  if [ "$already" != "true" ]; then
    # Explicit template: macOS `mktemp` with no template ignores TMPDIR.
    tmp="$(mktemp "${TMPDIR:-/tmp}/synapse-tags.XXXXXX")"
    jq --arg d "$REPOS_PARENT" '."parser-directories" = ((."parser-directories" // []) + [$d] | unique)' \
      "$TS_CONFIG" > "$tmp" 2>/dev/null && mv "$tmp" "$TS_CONFIG"
  fi

  printf '%s' "$scope"
}

# Prints a trailing newline on purpose: the batch path pipes this into `sort -u`,
# and without one every extension in the repo concatenates into a single token.
# The single-file caller reads it through `$(...)`, which strips it either way.
ext_of() { # ext_of <path> -- lowercased extension, empty when there is none
  local base ext
  base="$(basename "$1")"
  ext="${base##*.}"
  [ "$ext" != "$base" ] || return 1
  printf '%s\n' "$ext" | tr '[:upper:]' '[:lower:]'
}

if [ "$MODE" = "batch" ]; then
  # Every distinct extension gets its grammar prepared before the single
  # invocation below; without that, the first file of a language would be the
  # one that triggers a clone, mid-batch, with no way to retry it.
  #
  # Extensions come from one `awk` pass, NOT from `ext_of` in a loop: that helper
  # forks `basename` per path, which measured 4.4s for 200 files against 0.08s
  # for the tagging itself -- the per-file-fork trap, reintroduced inside the very
  # change that exists to remove per-file invocations.
  ready=0
  while IFS= read -r ext; do
    [ -n "$ext" ] || continue
    if ensure_grammar "$ext" >/dev/null; then
      ready=$((ready + 1))
    else
      case $? in
        2) echo "synapse-tags: no grammar registered for .$ext -- those files are skipped" >&2 ;;
        *) echo "synapse-tags: grammar for .$ext is not usable -- those files are skipped" >&2 ;;
      esac
    fi
  done < <(awk -F/ '{ f = $NF; n = split(f, a, "."); if (n > 1 && a[n] != "") print tolower(a[n]) }' \
             "$PATHS_FILE" | LC_ALL=C sort -u)

  [ "$ready" -gt 0 ] || exit 1

  # THE CLI CHANGES OUTPUT SHAPE AT ONE PATH, and this normalises it away.
  # Given two or more paths tree-sitter prints an unindented path line followed
  # by that path's tab-indented tags; given exactly ONE it prints neither, just
  # the bare tags -- indistinguishable from single-file form (verified against
  # tree-sitter 0.25.10). Callers batch by chunk, and a chunk of one is the
  # common case, not a corner: one source file changed, re-tag it. Left
  # un-normalised, an attributing caller reads the first tag line as a path,
  # finds the real path absent from the output, and concludes the file could
  # not be parsed -- caching a perfectly readable file as `unsupported`.
  #
  # So the contract this script advertises ("an unindented line is a path, the
  # tab-indented lines under it are that path's tags") is made true here rather
  # than in each caller, where three of them would have had to get it right.
  n_paths="$(LC_ALL=C awk 'NF { n++ } END { print n + 0 }' "$PATHS_FILE")"

  # stderr discarded: tree-sitter emits an eight-line warning per unsupported
  # FILE, and the per-extension lines above already said it once.
  if [ "$n_paths" -eq 1 ]; then
    # The grammar check above already exited 1 if this one file's extension had
    # none, so reaching here means it is genuinely parseable and deserves its
    # path line even when it yields no tags at all.
    LC_ALL=C awk 'NF { print; exit }' "$PATHS_FILE"
    tree-sitter tags --paths "$PATHS_FILE" 2>/dev/null | LC_ALL=C awk '{ print "\t" $0 }'
  else
    tree-sitter tags --paths "$PATHS_FILE" 2>/dev/null
  fi
  exit 0
fi

EXT="$(ext_of "$FILE")" || exit 1
SCOPE="$(ensure_grammar "$EXT")" || exit $?
tree-sitter tags --scope "$SCOPE" "$FILE" 2>/dev/null
