#!/bin/bash
# Read-only queries against a repo's Synapse graph. Reads the expensive parts
# internally and prints only what was asked for.
#
# Usage: synapse-query.sh <subcommand> [args]   (operates on the repo containing $PWD)
#
#   body    <node>                     fenced prose only, no frontmatter
#   sources <node>                     every path the node covers
#   sources <node> --count             just the number
#   sources <node> --modules           module<TAB>count, LC_ALL=C sorted
#   sources <node> --filter <pattern>  matching paths only (substring)
#   field   <node> <key>               one top-level frontmatter scalar
#   stale                              nodes whose files no longer match, with a reason
#   drift                              what changed since each node's recorded commit
#
# <node> may be given with or without the trailing `.md`.
#
# `stale` re-hashes what a node claims; `drift` diffs its recorded `commit` against
# HEAD, so only `drift` sees added, deleted and renamed paths. Neither pulls.
# When to use which, and why any of this is a script: docs/synapse.md.
#
# Exit codes:
#   0 - ran successfully. Empty output from `stale`/`drift` means clean; `drift`
#       prints context (commits behind, commits since baseline) only alongside a
#       finding, so silence means the graph matches the worktree.
#   1 - could not run (missing dependency, no vault, no namespace, remote
#       mismatch, unknown node). Treat as "no information", never as "clean".
#   2 - usage error (unknown subcommand, bad flag, unsupported field)
set -uo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
  awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
  exit "${1:-2}"
}

SUB="${1:-}"
[ -n "$SUB" ] || usage
shift

# Validate the subcommand *before* the preamble below. A usage error is a
# property of the arguments, not of the environment -- reporting "could not
# run" (exit 1) for a typo'd subcommand just because Obsidian happens to be
# down would send the caller looking in the wrong place entirely.
case "$SUB" in
  body|sources|field|stale|drift) ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac

CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 1

command -v jq >/dev/null || exit 1
command -v git >/dev/null || exit 1

# sha256, portable across macOS (shasum) and most Linux (sha256sum). Only the
# `stale` subcommand needs it; checked up front because it is cheap and a
# missing digest tool should fail as "cannot run", not midway through a loop.
if command -v shasum >/dev/null; then
  sha256() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null; then
  sha256() { sha256sum | cut -d' ' -f1; }
else
  exit 1
fi

PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"
[ -f "$PLUGIN_DATA" ] && [ -f "$CERT" ] || exit 1
API_KEY="$(jq -r '.apiKey // empty' "$PLUGIN_DATA")"
PORT="$(jq -r '.port // empty' "$PLUGIN_DATA")"
[ -n "$API_KEY" ] && [ -n "$PORT" ] || exit 1
BASE="https://127.0.0.1:$PORT"

REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || exit 1
REPO_NAME="$(basename "$REPO_ROOT")"

# Same origin -> first-remote -> repo-root resolution the SessionStart hook and
# synapse-staleness.sh use. It must match exactly, or a repo without an `origin`
# compares unequal against its own namespace.
REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE" ]; then
  FIRST_REMOTE="$(git -C "$REPO_ROOT" remote 2>/dev/null | head -1 || true)"
  [ -n "$FIRST_REMOTE" ] && REMOTE="$(git -C "$REPO_ROOT" remote get-url "$FIRST_REMOTE" 2>/dev/null || true)"
fi
[ -n "$REMOTE" ] || REMOTE="$REPO_ROOT"

urlencode_path() {
  local path="$1" seg out=()
  local IFS='/'
  read -ra parts <<< "$path"
  for seg in "${parts[@]}"; do
    out+=("$(jq -rn --arg s "$seg" '$s|@uri')")
  done
  local IFS='/'
  echo "${out[*]}"
}

api_get_to() { # api_get_to <vault-path> <dest-file>
  curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
    -H "Accept: text/markdown" -o "$2" "$BASE/vault/$(urlencode_path "$1")"
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- namespace exists, and belongs to this repo -----------------------------
api_get_to "synapse/$REPO_NAME/Index.md" "$WORK/Index.md" || exit 1
EXISTING_REMOTE="$(grep -m1 '^remote:' "$WORK/Index.md" | sed -e 's/^remote: *//' -e 's/^"//' -e 's/"$//')"
[ "$EXISTING_REMOTE" = "$REMOTE" ] || exit 1

# --- shared helpers ---------------------------------------------------------

# Fetches a node into $WORK/node.md. Accepts the title with or without `.md`.
fetch_node() { # fetch_node <node>
  local node="$1"
  case "$node" in *.md) ;; *) node="$node.md" ;; esac
  api_get_to "synapse/$REPO_NAME/$node" "$WORK/node.md" || return 1
  printf '%s' "$node"
}

extract_source_paths() { # frontmatter `  - path: X` lines, in file order
  awk '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "")
      print
    }
  ' "$1"
}

# Aggregation key for --modules. Everything up to the first `src` segment, so
# `lightweight/lightweight-impl/src/main/java/...` groups as
# `lightweight/lightweight-impl` while `gui-utc-core/src/...` stays
# `gui-utc-core`. MUST match the rule /synapse-init uses for the `## Sources`
# mirror -- two groupings for one concept is a divergence nobody notices for
# months.
module_of() { # module_of <path>
  local p="$1"
  case "$p" in
    */src/*) printf '%s' "${p%%/src/*}" ;;
    */*) printf '%s' "${p%%/*}" ;;
    *) printf '(repo root)' ;;
  esac
}

# --- subcommands ------------------------------------------------------------

cmd_body() {
  local node="${1:-}"; [ -n "$node" ] || usage
  fetch_node "$node" >/dev/null || exit 1
  # Between the generated fences: excludes the frontmatter *and* `## Notes`,
  # which is strictly better than reading from after the closing `---`.
  if grep -q '<!-- synapse:generated:start -->' "$WORK/node.md"; then
    sed -n '/<!-- synapse:generated:start -->/,/<!-- synapse:generated:end -->/p' "$WORK/node.md" \
      | sed -e '1d' -e '$d'
    return 0
  fi
  # A node built before fencing existed: fall back to everything after the
  # closing `---`, and say so, since `## Notes` will be included.
  echo "synapse-query: no generated fence in '$node'; printing everything after the frontmatter" >&2
  awk 'NR==1 && $0=="---" { in_fm=1; next } in_fm && $0=="---" { in_fm=0; body=1; next } body' "$WORK/node.md"
}

cmd_sources() {
  local node="${1:-}"; [ -n "$node" ] || usage
  shift || true
  local mode="all" pattern=""
  case "${1:-}" in
    "") ;;
    --count) mode="count" ;;
    --modules) mode="modules" ;;
    --filter) mode="filter"; pattern="${2:-}"; [ -n "$pattern" ] || usage ;;
    *) usage ;;
  esac

  fetch_node "$node" >/dev/null || exit 1
  extract_source_paths "$WORK/node.md" > "$WORK/paths.txt"

  case "$mode" in
    count) wc -l < "$WORK/paths.txt" | tr -d ' ' ;;
    filter) grep -F -- "$pattern" "$WORK/paths.txt" || true ;;
    modules)
      while IFS= read -r p; do
        [ -n "$p" ] && module_of "$p" && printf '\n'
      done < "$WORK/paths.txt" | LC_ALL=C sort | uniq -c \
        | awk '{ n=$1; $1=""; sub(/^ /,""); printf "%s\t%d\n", $0, n }'
      ;;
    all) cat "$WORK/paths.txt" ;;
  esac
}

cmd_field() {
  local node="${1:-}" key="${2:-}"
  [ -n "$node" ] && [ -n "$key" ] || usage
  # `sources` is a list of objects, not a scalar -- that is what `sources` is for.
  if [ "$key" = "sources" ]; then
    echo "synapse-query: 'sources' is a list, not a scalar field -- use: synapse-query.sh sources <node>" >&2
    exit 2
  fi
  fetch_node "$node" >/dev/null || exit 1
  # First match inside the frontmatter only, quotes stripped. Absent key prints
  # nothing and exits 0, so callers can test emptiness without parsing an error.
  awk -v k="$key" '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && index($0, k ":") == 1 {
      sub("^" k ":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$WORK/node.md"
}

cmd_stale() {
  [ $# -eq 0 ] || usage
  api_get_to "synapse/$REPO_NAME/_index.json" "$WORK/_index.json" || exit 1
  jq -e . "$WORK/_index.json" >/dev/null 2>&1 || exit 1

  # Node list comes from _index.json's values -- authoritative for which nodes
  # exist, and already in hand, so no directory listing is needed.
  jq -r 'to_entries | map(select(.key != "_unassigned")) | map(.value[]) | unique | .[]' \
    "$WORK/_index.json" > "$WORK/nodes.txt" 2>/dev/null || exit 1

  # The node's `sources` is the authority on what it covers, not _index.json --
  # verifying against the index instead would mask node/index drift, and would
  # report a false mismatch whenever the two disagree for an unrelated reason.
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    if ! api_get_to "synapse/$REPO_NAME/$node" "$WORK/node.md"; then
      printf '%s\tnode file missing from the vault\n' "${node%.md}"
      continue
    fi

    STORED="$(grep -m1 '^sources_digest:' "$WORK/node.md" | sed -e 's/^sources_digest: *//' -e 's/^"//' -e 's/"$//')"
    if [ -z "$STORED" ]; then
      printf '%s\tno sources_digest (built before the digest existed)\n' "${node%.md}"
      continue
    fi

    extract_source_paths "$WORK/node.md" > "$WORK/paths.txt"
    if [ ! -s "$WORK/paths.txt" ]; then
      printf '%s\tno sources listed\n' "${node%.md}"
      continue
    fi

    # A recorded file that no longer exists is staleness, and `git hash-object`
    # would fail the whole batch on it -- so check first and report by name.
    MISSING="$(while IFS= read -r p; do
      [ -f "$REPO_ROOT/$p" ] || printf '%s ' "$p"
    done < "$WORK/paths.txt")"
    if [ -n "$MISSING" ]; then
      printf '%s\tsource files gone: %s\n' "${node%.md}" "${MISSING% }"
      continue
    fi

    HASHES="$(cd "$REPO_ROOT" && git hash-object --stdin-paths < "$WORK/paths.txt" 2>/dev/null)"
    [ -n "$HASHES" ] || { printf '%s\thashing failed\n' "${node%.md}"; continue; }

    # Digest definition, pinned in /synapse-init: sha256 over the LC_ALL=C
    # sorted "path:hash" lines, newline-joined, no trailing newline. $(...)
    # strips trailing newlines and printf '%s' adds none back.
    JOINED="$(paste -d: "$WORK/paths.txt" <(printf '%s\n' "$HASHES") | LC_ALL=C sort)"
    CURRENT="$(printf '%s' "$JOINED" | sha256)"

    [ "$CURRENT" = "$STORED" ] || printf '%s\tcontent changed\n' "${node%.md}"
  done < "$WORK/nodes.txt"
}

# Reads one top-level frontmatter scalar out of an already-fetched node file.
frontmatter_field() { # frontmatter_field <file> <key>
  awk -v k="$2" '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && index($0, k ":") == 1 {
      sub("^" k ":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$1"
}

# Both inputs must be LC_ALL=C sorted: this is an intersection, not a scan per path.
count_intersect() { # count_intersect <sorted-node-paths> <sorted-changed-paths>
  comm -12 "$1" "$2" | grep -c . || true
}

cmd_drift() {
  [ $# -eq 0 ] || usage
  command -v comm >/dev/null || exit 1

  api_get_to "synapse/$REPO_NAME/_index.json" "$WORK/_index.json" || exit 1
  jq -e . "$WORK/_index.json" >/dev/null 2>&1 || exit 1
  jq -r 'to_entries | map(select(.key != "_unassigned")) | map(.value[]) | unique | .[]' \
    "$WORK/_index.json" > "$WORK/nodes.txt" 2>/dev/null || exit 1

  # Findings are buffered rather than printed as they are found, so that silence can
  # mean "the graph matches the worktree". Context -- how far behind upstream, how
  # many commits since a baseline -- is only worth printing next to a finding; on its
  # own it is a git fact, not graph drift.
  : > "$WORK/found-repo.txt"
  : > "$WORK/found-nodes.txt"
  : > "$WORK/baselines.txt"
  : > "$WORK/node-baseline.tsv"
  : > "$WORK/dirty-baselines.txt"
  : > "$WORK/divergent-baselines.txt"

  while IFS= read -r node; do
    [ -n "$node" ] || continue
    if ! api_get_to "synapse/$REPO_NAME/$node" "$WORK/node.md"; then
      printf '%s\tnode file missing from the vault\n' "${node%.md}" >> "$WORK/found-nodes.txt"
      continue
    fi
    baseline="$(frontmatter_field "$WORK/node.md" commit)"
    if [ -z "$baseline" ]; then
      printf '%s\tno commit recorded, so nothing to diff against -- verify with `stale`\n' "${node%.md}" >> "$WORK/found-nodes.txt"
      continue
    fi
    if ! git -C "$REPO_ROOT" cat-file -e "$baseline^{commit}" 2>/dev/null; then
      printf '%s\tbaseline %s not in local history -- verify with `stale`\n' \
        "${node%.md}" "$(printf '%s' "$baseline" | cut -c1-12)" >> "$WORK/found-nodes.txt"
      continue
    fi
    printf '%s\n' "$baseline" >> "$WORK/baselines.txt"
    extract_source_paths "$WORK/node.md" | LC_ALL=C sort > "$WORK/paths-$node.txt"
    printf '%s\t%s\n' "$node" "$baseline" >> "$WORK/node-baseline.tsv"
  done < "$WORK/nodes.txt"

  # One diff per distinct baseline: nodes built in the same run share a commit.
  while IFS= read -r base; do
    d="$WORK/diff-$base"
    [ -f "$d.raw" ] && continue
    git -C "$REPO_ROOT" diff --name-status -M "$base..HEAD" > "$d.raw" 2>/dev/null || : > "$d.raw"
    # A rename line is `R100<TAB>old<TAB>new`; the old path is what a node still
    # lists, so that is the one to intersect against.
    awk -F'\t' '$1 ~ /^M/ { print $2 }' "$d.raw" | LC_ALL=C sort > "$d.mod"
    awk -F'\t' '$1 ~ /^D/ { print $2 }' "$d.raw" | LC_ALL=C sort > "$d.del"
    awk -F'\t' '$1 ~ /^R/ { print $2 }' "$d.raw" | LC_ALL=C sort > "$d.ren"
    awk -F'\t' '$1 ~ /^A/ { print $2 }' "$d.raw" | LC_ALL=C sort > "$d.add"

    # Divergence is a finding in its own right: the graph was built against a line
    # this checkout is not on, whatever the file-level diff says.
    if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
      printf '%s\n' "$base" >> "$WORK/divergent-baselines.txt"
      LR="$(git -C "$REPO_ROOT" rev-list --left-right --count "$base...HEAD" 2>/dev/null || echo '0	0')"
      printf '(repo)\tbaseline %s is not an ancestor of HEAD: %s commits only on the baseline, %s only here -- the graph describes a different line\n' \
        "$(printf '%s' "$base" | cut -c1-12)" "$(printf '%s' "$LR" | cut -f1)" "$(printf '%s' "$LR" | cut -f2)" \
        >> "$WORK/found-repo.txt"
    fi
  done < <(LC_ALL=C sort -u "$WORK/baselines.txt")

  while IFS=$'\t' read -r node base; do
    [ -n "$node" ] || continue
    d="$WORK/diff-$base"
    p="$WORK/paths-$node.txt"
    n_mod="$(count_intersect "$p" "$d.mod")"
    n_del="$(count_intersect "$p" "$d.del")"
    n_ren="$(count_intersect "$p" "$d.ren")"
    if [ "$n_mod" -gt 0 ] || [ "$n_del" -gt 0 ] || [ "$n_ren" -gt 0 ]; then
      printf '%s\n' "$base" >> "$WORK/dirty-baselines.txt"
    fi
    [ "$n_mod" -gt 0 ] && printf '%s\tcontent changed in %s of its files\n' "${node%.md}" "$n_mod" >> "$WORK/found-nodes.txt"
    # Renames are the one class fixable without re-authoring: the concept is
    # unchanged, only the paths moved.
    [ "$n_ren" -gt 0 ] && printf '%s\t%s of its files were renamed -- reseat sources, prose may still hold\n' "${node%.md}" "$n_ren" >> "$WORK/found-nodes.txt"
    [ "$n_del" -gt 0 ] && printf '%s\t%s of its files are gone\n' "${node%.md}" "$n_del" >> "$WORK/found-nodes.txt"
  done < "$WORK/node-baseline.tsv"

  # Added paths that no node claims. Split by whether a manifest pattern would
  # already claim them, so only the remainder needs a decision.
  cat "$WORK"/diff-*.add 2>/dev/null | LC_ALL=C sort -u > "$WORK/added.txt"
  if [ -s "$WORK/added.txt" ]; then
    jq -r 'keys[]' "$WORK/_index.json" | LC_ALL=C sort > "$WORK/claimed.txt"
    comm -23 "$WORK/added.txt" "$WORK/claimed.txt" > "$WORK/unclaimed.txt"
    if [ -s "$WORK/unclaimed.txt" ]; then
      MANIFEST=""
      if api_get_to "synapse/$REPO_NAME/_manifest.tsv" "$WORK/manifest.tsv"; then
        MANIFEST="$WORK/manifest.tsv"
      elif [ -f "${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}/manifest.tsv" ]; then
        MANIFEST="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}/manifest.tsv"
      fi
      if [ -n "$MANIFEST" ]; then
        : > "$WORK/needs-decision.txt"
        AUTO=0
        while IFS= read -r path; do
          matched=0
          while IFS=$'\t' read -r title inc exc; do
            [ -n "$title" ] || continue
            printf '%s\n' "$path" | grep -qE "$inc" || continue
            printf '%s\n' "$path" | grep -qE "${exc:-^\$}" && continue
            matched=1
            break
          done < "$MANIFEST"
          if [ "$matched" -eq 1 ]; then
            AUTO=$((AUTO + 1))
          else
            printf '%s\n' "$path" >> "$WORK/needs-decision.txt"
          fi
        done < "$WORK/unclaimed.txt"
        [ "$AUTO" -gt 0 ] && printf '(repo)\t%s new paths already match a manifest pattern -- re-run synapse-build-lists.sh to claim them\n' "$AUTO" >> "$WORK/found-repo.txt"
        if [ -s "$WORK/needs-decision.txt" ]; then
          printf '(repo)\t%s new paths match no manifest pattern: %s\n' \
            "$(grep -c . "$WORK/needs-decision.txt")" \
            "$(head -5 "$WORK/needs-decision.txt" | tr '\n' ' ')" >> "$WORK/found-repo.txt"
        fi
      else
        printf '(repo)\t%s new paths claimed by no node, and no manifest to classify them against\n' \
          "$(grep -c . "$WORK/unclaimed.txt")" >> "$WORK/found-repo.txt"
      fi
    fi
  fi

  # Nothing to report: stay silent, so silence is a usable signal.
  [ -s "$WORK/found-repo.txt" ] || [ -s "$WORK/found-nodes.txt" ] || return 0

  # Context, printed only now that there is a finding to attach it to.
  UPSTREAM="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [ -n "$UPSTREAM" ]; then
    BEHIND="$(git -C "$REPO_ROOT" rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)"
    # Never fetches, so this is the state as of the last fetch.
    [ "$BEHIND" -gt 0 ] && printf '(repo)\t%s commits behind %s, as of the last fetch\n' "$BEHIND" "$UPSTREAM"
  fi
  while IFS= read -r base; do
    # Skipped for a divergent baseline: `--count base..HEAD` is the one-directional
    # number, and the divergence line above already reports both sides.
    grep -qxF "$base" "$WORK/divergent-baselines.txt" && continue
    COMMITS="$(git -C "$REPO_ROOT" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
    [ "$COMMITS" -gt 0 ] && printf '(repo)\t%s commits since baseline %s\n' \
      "$COMMITS" "$(printf '%s' "$base" | cut -c1-12)"
  done < <(LC_ALL=C sort -u "$WORK/dirty-baselines.txt")
  cat "$WORK/found-repo.txt"
  cat "$WORK/found-nodes.txt"
}


# $SUB was validated above, so this needs no catch-all.
case "$SUB" in
  body)    cmd_body "$@" ;;
  sources) cmd_sources "$@" ;;
  field)   cmd_field "$@" ;;
  stale)   cmd_stale "$@" ;;
  drift)   cmd_drift "$@" ;;
esac
