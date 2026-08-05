#!/bin/bash
# Writes one Synapse node into the vault: hashes every source path, computes
# sources_digest, records the baseline `commit`, builds the aggregated `## Sources`
# mirror, and PUTs the note via the Obsidian Local REST API.
#
# Usage: synapse-write-node.sh --title <t> --summary <s> --paths <file> --body <file>
#        synapse-write-node.sh --help
#
#   --title    node title. Used verbatim as the H1, and sanitized for the filename.
#   --summary  one line for the index bullet, stored as the `summary` frontmatter
#              field. Written for the index, not as the node's opening sentence.
#   --paths    file of repo-relative paths, one per line: every file the node covers.
#   --body     file holding the authored prose (## Summary / ## Crux / ## Links).
#              `## Sources` and the generated fences are added by this script.
#
# The body must not contain crux code. It points instead:
#
#   <!-- crux: crates/matcher/src/lib.rs 412-419 -->     slice these lines
#   <!-- crux: none -->                                  no single span carries it
#
# This script cuts the text out of the file, fences it with a language guessed
# from the extension, appends a `path:start-end` provenance line, and records
# `crux_path`/`crux_lines` in frontmatter. The path must be one the node claims
# and the range must be under 20 lines, or the write is refused.
#
# The body may also carry any number of grounding pointers — the evidence a
# summary rests on, typically a doc comment or a test:
#
#   <!-- grounded_in: src/main/java/Foo.java 10-14 -->
#
# These are recorded in the `grounded_in` frontmatter list as path + lines +
# sha256 of the sliced text, then stripped from the body: provenance, not
# display. Same path and range checks as the crux, with a 40-line cap.
#
# Writes to the vault over the Obsidian Local REST API on 127.0.0.1. Agent callers
# need the network sandbox disabled, or curl fails with exit 7 and no message.
#
# Exit codes:
#   0 - node written; prints "<file>\t<n> files\t<digest>"
#   1 - could not run (missing dependency, no vault, remote mismatch, PUT failed)
#   2 - usage error
#
# Design rationale lives in docs/synapse-graph.md, not here.
set -euo pipefail

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
readonly CONF
readonly CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"

# Prints the header block, so help and the generated reference cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

node_title=""
node_summary=""
paths_file=""
body_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --title)   node_title="${2:-}"; shift 2 || usage ;;
        --summary) node_summary="${2:-}"; shift 2 || usage ;;
        --paths)   paths_file="${2:-}"; shift 2 || usage ;;
        --body)    body_file="${2:-}"; shift 2 || usage ;;
        *) usage ;;
    esac
done

[[ -n "$node_title" && -n "$node_summary" && -n "$paths_file" && -n "$body_file" ]] || usage
[[ -s "$paths_file" ]] || { echo "synapse-write-node: empty path list: $paths_file" >&2; exit 1; }
[[ -f "$body_file" ]] || { echo "synapse-write-node: no body file: $body_file" >&2; exit 1; }

# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[[ -n "$VAULT" && -d "$VAULT" ]] || { echo "synapse-write-node: no vault" >&2; exit 1; }

# Boilerplate path-segment chains for the `## Sources` mirror below -- must
# stay identical to synapse-query.sh's own MODULE_BOILERPLATE loading, or the
# mirror and `sources --modules` disagree. See synapse-module-boilerplate.conf.
MODULE_BOILERPLATE_CONF="$HOME/.claude/synapse-module-boilerplate.conf"
MODULE_BOILERPLATE=()
if [[ -f "$MODULE_BOILERPLATE_CONF" ]]; then
  while IFS= read -r chain; do
    chain="${chain%%#*}"
    chain="$(printf '%s' "$chain" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$chain" ]] && MODULE_BOILERPLATE+=("$chain")
  done < "$MODULE_BOILERPLATE_CONF"
fi

command -v jq >/dev/null || { echo "synapse-write-node: jq required" >&2; exit 1; }
command -v git >/dev/null || { echo "synapse-write-node: git required" >&2; exit 1; }

if command -v shasum >/dev/null; then
    sha256() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null; then
    sha256() { sha256sum | cut -d' ' -f1; }
else
    echo "synapse-write-node: no sha256 tool" >&2; exit 1
fi

readonly PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
[[ -f "$PLUGIN_DATA" && -f "$CERT" ]] || { echo "synapse-write-node: REST API not configured" >&2; exit 1; }
API_KEY="$(jq -r '.apiKey // empty' "$PLUGIN_DATA")"
PORT="$(jq -r '.port // empty' "$PLUGIN_DATA")"
[[ -n "$API_KEY" && -n "$PORT" ]] || { echo "synapse-write-node: no API key/port" >&2; exit 1; }
BASE="https://127.0.0.1:$PORT"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-write-node: not inside a git repo" >&2; exit 1; }
REPO_NAME="$(basename "$REPO_ROOT")"

# Same origin -> first-remote -> repo-root resolution the SessionStart hook,
# synapse-staleness.sh and synapse-query.sh use. It must match exactly, or a repo
# without an `origin` compares unequal against its own namespace.
REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [[ -z "$REMOTE" ]]; then
    first_remote="$(git -C "$REPO_ROOT" remote 2>/dev/null | head -1 || true)"
    [[ -n "$first_remote" ]] && REMOTE="$(git -C "$REPO_ROOT" remote get-url "$first_remote" 2>/dev/null || true)"
fi
[[ -n "$REMOTE" ]] || REMOTE="$REPO_ROOT"

# Explicit template: macOS `mktemp -d` with no template ignores TMPDIR and uses
# the per-user /var/folders dir, which a sandboxed caller cannot write.
work="$(mktemp -d "${TMPDIR:-/tmp}/synapse-node.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

urlencode_path() {
    local seg out=() parts
    local IFS='/'
    read -ra parts <<< "$1"
    for seg in "${parts[@]}"; do
        out+=("$(jq -rn --arg s "$seg" '$s|@uri')")
    done
    local IFS='/'
    echo "${out[*]}"
}

# --- refuse to write into another repo's namespace ---------------------------
# A namespace is keyed by directory basename, so two unrelated repos can collide.
# Absent Index.md means a first-time build is in progress, which is fine.
if curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
        -H "Accept: text/markdown" -o "$work/Index.md" \
        "$BASE/vault/$(urlencode_path "synapse/$REPO_NAME/Index.md")"; then
    existing_remote="$(grep -m1 '^remote:' "$work/Index.md" | sed -e 's/^remote: *//' -e 's/^"//' -e 's/"$//')"
    if [[ -n "$existing_remote" && "$existing_remote" != "$REMOTE" ]]; then
        echo "synapse-write-node: synapse/$REPO_NAME/ belongs to a different repo" >&2
        echo "  existing remote: $existing_remote" >&2
        echo "  this repo:       $REMOTE" >&2
        echo "  refusing to overwrite -- rename one of the two repos first" >&2
        exit 1
    fi
fi

# Obsidian resolves a wikilink by filename, so a sanitized title silently breaks
# inbound links. Hence the warning below rather than a silent rename.
file_title="$(printf '%s' "$node_title" | tr '/:*?"<>|' '_')"
if [[ "$file_title" != "$node_title" ]]; then
    echo "synapse-write-node: WARNING title needed sanitizing, so [[$node_title]] will not resolve" >&2
    echo "  filename: $file_title.md -- reword the title to avoid divergence" >&2
fi

# --- preserve everything after the generated region --------------------------
# Re-emit whatever follows the closing fence, so a rebuild cannot destroy
# human-authored `## Notes`. Falls back to a fresh empty section for a node that
# has never been written, or one built before fencing existed.
node_tail=""
if curl -s -f --cacert "$CERT" -H "Authorization: Bearer $API_KEY" \
        -H "Accept: text/markdown" -o "$work/existing.md" \
        "$BASE/vault/$(urlencode_path "synapse/$REPO_NAME/$file_title.md")" \
   && grep -q '<!-- synapse:generated:end -->' "$work/existing.md"; then
    node_tail="$(sed -n '/<!-- synapse:generated:end -->/,$p' "$work/existing.md" | sed '1d')"
fi

# --- hashes, in the same order as the (deduped, sorted) path list ------------
LC_ALL=C sort -u "$paths_file" > "$work/paths.txt"

# Check every path first: `git hash-object --stdin-paths` aborts the whole batch
# on the first bad entry, leaving the caller exit 128 and no offending path. Hits
# deleted paths and submodule gitlinks (one ls-files entry, but a directory on
# disk). Same -f pre-check as synapse-query.sh's `stale`.
bad_paths="$(while IFS= read -r p; do
    [[ -f "$REPO_ROOT/$p" ]] || printf '%s ' "$p"
done < "$work/paths.txt")"
if [[ -n "$bad_paths" ]]; then
    echo "synapse-write-node: not regular files in $REPO_ROOT: ${bad_paths% }" >&2
    echo "  (deleted since enumeration, or a submodule gitlink -- drop them from the list)" >&2
    exit 1
fi

(cd "$REPO_ROOT" && git hash-object --stdin-paths < "$work/paths.txt") > "$work/hashes.txt"

# --- baseline commit, for `synapse-query.sh drift` ---------------------------
# Full sha, never abbreviated: an abbreviation unique today can become ambiguous
# as history grows. Omitted, not empty, when HEAD does not resolve (nothing
# committed yet).
#
# `--verify --quiet`, not a bare `rev-parse HEAD`: without --verify git echoes the
# unresolvable name "HEAD" to stdout while failing, so the baseline would be set to
# that literal string and the diff below would die on it.
node_commit="$(git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD || true)"

# Hashes come from the worktree, so a dirty source makes the recorded commit
# approximate. Scoped to this node's own paths, to stay quiet during work
# elsewhere in the repo.
if [[ -n "$node_commit" ]]; then
    (cd "$REPO_ROOT" && git diff --name-only HEAD) | LC_ALL=C sort > "$work/dirty.txt"
    dirty_sources="$(LC_ALL=C comm -12 "$work/dirty.txt" "$work/paths.txt" | head -3 | tr '\n' ' ')"
    if [[ -n "$dirty_sources" ]]; then
        echo "synapse-write-node: NOTE uncommitted changes in this node's sources: ${dirty_sources% }" >&2
        echo "  commit: $node_commit records what was checked out, not a faithful drift baseline" >&2
    fi
fi

paths_n="$(wc -l < "$work/paths.txt" | tr -d ' ')"
hashes_n="$(wc -l < "$work/hashes.txt" | tr -d ' ')"
[[ "$paths_n" == "$hashes_n" ]] || {
    echo "synapse-write-node: hashed $hashes_n of $paths_n paths (a listed file may be missing, or be a submodule gitlink)" >&2
    exit 1
}

# --- sources_digest: sha256 over LC_ALL=C sorted "path:hash", no trailing NL --
# Definition pinned in /synapse-init and re-implemented in synapse-query.sh's
# `stale`; all three must agree or every node reports a false mismatch.
joined="$(paste -d: "$work/paths.txt" "$work/hashes.txt" | LC_ALL=C sort)"
digest="$(printf '%s' "$joined" | sha256)"

# --- `## Sources` mirror: module_of() identical to synapse-query.sh ----------
# Configured boilerplate chains (MODULE_BOILERPLATE, see
# synapse-module-boilerplate.conf) carry no subsystem information -- strip
# through to the segment before `src/`. A flat `<pkg>/src/<subsystem>/...`
# layout has no such boilerplate: the segment right after `src/` is the
# subsystem, so keep one. Else the first path component, else `(repo root)`.
# Two groupings for one concept is a divergence nobody notices for months, so
# this must not drift from synapse-query.sh's --modules.
boilerplate_joined="$(IFS='|'; printf '%s' "${MODULE_BOILERPLATE[*]:-}")"
awk -v chains="$boilerplate_joined" '
BEGIN { n = split(chains, C, "|") }
{
    m = ""
    for (i = 1; i <= n; i++) {
        if (C[i] == "") continue
        pat = "/" C[i] "/"
        p = index($0, pat)
        if (p > 0) { m = substr($0, 1, p - 1); break }
    }
    if (m == "") {
        if (match($0, /\/src\//)) {
            base = substr($0, 1, RSTART - 1)
            rest = substr($0, RSTART + 5)
            if (index(rest, "/")) { m = base "/src/" substr(rest, 1, index(rest, "/") - 1) }
            else { m = base }
        }
        else if (index($0, "/")) { m = substr($0, 1, index($0, "/") - 1) }
        else { m = "(repo root)" }
    }
    count[m]++
}
END { for (m in count) printf "%s\t%d\n", m, count[m] }' "$work/paths.txt" \
    | LC_ALL=C sort > "$work/modules.txt"

# --- crux: the body points, this script slices ------------------------------
# The body carries `<!-- crux: <path> <start>-<end> -->` (or `<!-- crux: none -->`)
# and never the code itself, so a crux cannot be a paraphrase of the source that
# merely looks like a quote. Adopted from Graft, which has the model return line
# numbers and cuts the text at write time. An HTML comment because an unexpanded
# directive then renders as nothing rather than as a broken code block.
crux_path=""
crux_lines=""
crux_directive="$(grep -m1 -oE '<!--[[:space:]]*crux:[^>]*-->' "$body_file" || true)"
if [[ -n "$crux_directive" ]]; then
    crux_arg="$(printf '%s' "$crux_directive" \
        | sed -E 's/^<!--[[:space:]]*crux:[[:space:]]*//; s/[[:space:]]*-->$//')"
    if [[ "$crux_arg" == "none" ]]; then
        : > "$work/crux.md"
        printf '_No single span carries this node'\''s logic._\n' > "$work/crux.md"
    else
        # `path start-end`, with L-prefixes tolerated on either bound.
        crux_path="${crux_arg%%[[:space:]]*}"
        crux_range="${crux_arg##*[[:space:]]}"
        crux_range="${crux_range//L/}"
        crux_start="${crux_range%%-*}"
        crux_end="${crux_range##*-}"
        [[ "$crux_path" != "$crux_arg" && "$crux_start" =~ ^[0-9]+$ && "$crux_end" =~ ^[0-9]+$ ]] || {
            echo "synapse-write-node: bad crux directive: $crux_directive" >&2
            echo "  expected: <!-- crux: path/to/file.ext 412-419 -->  (or 'none')" >&2
            exit 1
        }
        # The crux must quote a file the node actually claims. Without this a node
        # could cite code it does not cover, which is the failure the pointer is
        # meant to make impossible.
        grep -qxF "$crux_path" "$work/paths.txt" || {
            echo "synapse-write-node: crux path is not in this node's sources: $crux_path" >&2
            exit 1
        }
        [[ -f "$REPO_ROOT/$crux_path" ]] || {
            echo "synapse-write-node: crux path does not exist: $crux_path" >&2
            exit 1
        }
        total="$(wc -l < "$REPO_ROOT/$crux_path" | tr -d ' ')"
        (( crux_start >= 1 && crux_end >= crux_start && crux_end <= total )) || {
            echo "synapse-write-node: crux range $crux_start-$crux_end outside $crux_path (1-$total)" >&2
            exit 1
        }
        (( crux_end - crux_start < 20 )) || {
            echo "synapse-write-node: crux range $crux_start-$crux_end is $((crux_end - crux_start + 1)) lines; keep it under 20" >&2
            echo "  a crux is the few lines carrying the decision, not the whole function" >&2
            exit 1
        }
        case "$crux_path" in
            *.java) lang=java ;; *.kt|*.kts) lang=kotlin ;; *.rs) lang=rust ;;
            *.py) lang=python ;; *.ts|*.tsx) lang=typescript ;; *.js|*.mjs|*.cjs) lang=javascript ;;
            *.go) lang=go ;; *.rb) lang=ruby ;; *.sh|*.bash) lang=bash ;;
            *.ml|*.mli) lang=ocaml ;; *.sql) lang=sql ;; *.xml) lang=xml ;;
            *.yml|*.yaml) lang=yaml ;; *.json) lang=json ;; *) lang="" ;;
        esac
        {
            printf '```%s\n' "$lang"
            sed -n "${crux_start},${crux_end}p" "$REPO_ROOT/$crux_path"
            printf '```\n'
            printf '— `%s`:%s-%s\n' "$crux_path" "$crux_start" "$crux_end"
        } > "$work/crux.md"
        crux_lines="$crux_start-$crux_end"
    fi
    # Substitute the directive line for the sliced block, in place.
    awk -v marker="$crux_directive" -v f="$work/crux.md" '
        index($0, marker) { while ((getline line < f) > 0) print line; close(f); next }
        { print }' "$body_file" > "$work/body-expanded.md"
    body_file="$work/body-expanded.md"
fi

# --- grounded_in: the evidence a summary rests on ---------------------------
# `<!-- grounded_in: <path> <start>-<end> -->`, repeatable. Points at what the
# codebase asserts about itself -- a doc comment, a test name, an assertion -- so
# a summary can be traced instead of taken on faith. Provenance, not display:
# these are recorded in frontmatter and stripped from the body, because six
# groundings rendered as six code blocks would bury the prose a human came for.
#
# Only the digest of the sliced text is stored, never the text. That keeps the
# field small, avoids escaping multi-line code into YAML, and makes verification
# mechanical -- re-slice, re-hash, compare -- the same trick `sources_digest`
# uses. Digesting the slice rather than the whole file is the point: a file
# changing elsewhere leaves the grounding intact, which is a far sharper signal
# than "N% of this node's lines moved".
: > "$work/grounded.txt"
if grep -qE '<!--[[:space:]]*grounded_in:' "$body_file"; then
    grep -oE '<!--[[:space:]]*grounded_in:[^>]*-->' "$body_file" > "$work/g-directives.txt"
    while IFS= read -r directive; do
        arg="$(printf '%s' "$directive" \
            | sed -E 's/^<!--[[:space:]]*grounded_in:[[:space:]]*//; s/[[:space:]]*-->$//')"
        g_path="${arg%%[[:space:]]*}"
        g_range="${arg##*[[:space:]]}"
        g_range="${g_range//L/}"
        g_start="${g_range%%-*}"
        g_end="${g_range##*-}"
        [[ "$g_path" != "$arg" && "$g_start" =~ ^[0-9]+$ && "$g_end" =~ ^[0-9]+$ ]] || {
            echo "synapse-write-node: bad grounded_in directive: $directive" >&2
            echo "  expected: <!-- grounded_in: path/to/file.ext 10-14 -->" >&2
            exit 1
        }
        grep -qxF "$g_path" "$work/paths.txt" || {
            echo "synapse-write-node: grounded_in path is not in this node's sources: $g_path" >&2
            exit 1
        }
        [[ -f "$REPO_ROOT/$g_path" ]] || {
            echo "synapse-write-node: grounded_in path does not exist: $g_path" >&2
            exit 1
        }
        g_total="$(wc -l < "$REPO_ROOT/$g_path" | tr -d ' ')"
        (( g_start >= 1 && g_end >= g_start && g_end <= g_total )) || {
            echo "synapse-write-node: grounded_in range $g_start-$g_end outside $g_path (1-$g_total)" >&2
            exit 1
        }
        # Roomier than the crux cap: a doc comment or a test body is legitimately
        # longer than the few lines that carry a decision.
        (( g_end - g_start < 40 )) || {
            echo "synapse-write-node: grounded_in range $g_start-$g_end is $((g_end - g_start + 1)) lines; keep it under 40" >&2
            exit 1
        }
        g_digest="$(sed -n "${g_start},${g_end}p" "$REPO_ROOT/$g_path" | sha256)"
        printf '%s\t%s-%s\t%s\n' "$g_path" "$g_start" "$g_end" "$g_digest" >> "$work/grounded.txt"
    done < "$work/g-directives.txt"
    # Strip the directives: they are recorded above, and the body is for prose.
    grep -vE '^[[:space:]]*<!--[[:space:]]*grounded_in:[^>]*-->[[:space:]]*$' "$body_file" \
        | sed -E 's/<!--[[:space:]]*grounded_in:[^>]*-->//g' > "$work/body-grounded.md"
    body_file="$work/body-grounded.md"
fi

built_at="$(date '+%Y-%m-%d %H:%M')"

# --- assemble the note ------------------------------------------------------
{
    echo '---'
    printf 'title: "%s"\n' "$node_title"
    # Escaped for a YAML double-quoted scalar: backslash first, then quote, or the
    # escaping escapes itself. A summary is prose and will eventually contain both.
    yaml_summary="${node_summary//\\/\\\\}"
    yaml_summary="${yaml_summary//\"/\\\"}"
    printf 'summary: "%s"\n' "$yaml_summary"
    echo 'node_type: synapse-node'
    printf 'project: %s\n' "$REPO_NAME"
    echo 'sources:'
    paste "$work/paths.txt" "$work/hashes.txt" \
        | awk -F'\t' '{ printf "  - path: %s\n    hash: %s\n", $1, $2 }'
    printf 'sources_digest: %s\n' "$digest"
    echo 'stale: false'
    printf 'built_at: "%s"\n' "$built_at"
    # An `if` rather than `[[ ... ]] && printf`: a failing test as part of an
    # and-list is exactly how `set -e` kills a script by surprise.
    if [[ -n "$node_commit" ]]; then
        printf 'commit: %s\n' "$node_commit"
    fi
    # The pointer as well as the sliced text: this is what lets a later check
    # re-slice the same range and compare, rather than trusting the stored quote.
    if [[ -n "$crux_path" ]]; then
        printf 'crux_path: %s\n' "$crux_path"
        printf 'crux_lines: "%s"\n' "$crux_lines"
    fi
    if [[ -s "$work/grounded.txt" ]]; then
        echo 'grounded_in:'
        awk -F'\t' '{ printf "  - path: %s\n    lines: \"%s\"\n    digest: %s\n", $1, $2, $3 }' \
            "$work/grounded.txt"
    fi
    echo '---'
    echo
    printf '# %s\n' "$node_title"
    echo '<!-- synapse:generated:start -->'
    echo
    # Trim leading/trailing blank lines, so recovering a body from a node and writing
    # it back is idempotent rather than accreting padding on every reseat.
    awk '{ a[NR] = $0 }
         END {
           first = 1; while (first <= NR && a[first] ~ /^[[:space:]]*$/) first++
           last = NR;  while (last >= first && a[last] ~ /^[[:space:]]*$/) last--
           for (i = first; i <= last; i++) print a[i]
         }' "$body_file"
    echo
    echo '## Sources'
    awk -F'\t' '{ printf "- `%s` (%d)\n", $1, $2 }' "$work/modules.txt"
    echo '<!-- synapse:generated:end -->'
    if [[ -n "$node_tail" ]]; then
        printf '%s\n' "$node_tail"
    else
        echo
        echo '## Notes'
        echo
    fi
} > "$work/note.md"

# --- PUT into the vault -----------------------------------------------------
# Overwrites the generated region; $node_tail above carries everything after it.
http_code="$(curl -s -o "$work/resp" -w '%{http_code}' -X PUT \
    --cacert "$CERT" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: text/markdown" \
    --data-binary "@$work/note.md" \
    "$BASE/vault/$(urlencode_path "synapse/$REPO_NAME/$file_title.md")")"

case "$http_code" in
    20*) printf '%s\t%s files\t%s\n' "$file_title.md" "$paths_n" "$digest" ;;
    *) echo "synapse-write-node: PUT failed ($http_code): $(cat "$work/resp")" >&2; exit 1 ;;
esac
