#!/bin/bash
# Enumerates a repo's tracked files and expands a node manifest into one path
# list per node, then reports coverage. Step 1 of a scripted /synapse-init.
#
# Usage: synapse-build-lists.sh [--reenumerate]
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo-name}/.
#   Never the script's own location, and never the repo -- see below.
#
# Reads   $SYNAPSE_WORK_DIR/manifest.tsv   title <TAB> include-ERE <TAB> exclude-ERE
# Writes  $SYNAPSE_WORK_DIR/all.txt        enumerated tracked files (kept if present)
#         $SYNAPSE_WORK_DIR/lists/NN.txt   one path list per manifest line
#         $SYNAPSE_WORK_DIR/lists/NN.title the node title for that list
#         $SYNAPSE_WORK_DIR/unassigned.txt files no node claimed
#
# Coverage is the point: it prints enumerated/covered/unassigned counts on every
# run, so "did I drop 4,000 files with a bad regex" is a number rather than a
# hope. A pattern slip (`config$` matching only a file literally named config)
# shows up here instead of silently landing in _unassigned.
#
# Exit codes: 0 ok, 1 could not run, 2 usage error
set -euo pipefail

reenumerate=false
case "${1:-}" in
    "") ;;
    --reenumerate) reenumerate=true ;;
    *) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

command -v git >/dev/null || { echo "synapse-build-lists: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-build-lists: not inside a git repo" >&2; exit 1; }
REPO_NAME="$(basename "$REPO_ROOT")"

# The default must not be $PWD. These scripts resolve the repo from $PWD, so they
# are always run from inside it -- a $PWD default would drop all.txt (megabytes on
# a large repo), lists/, the manifest and the coverage files straight into the
# user's checkout. Keyed per repo so a re-run finds the previous manifest, and kept
# out of the vault so Obsidian never indexes a 125k-line file list.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
mkdir -p "$WORK_DIR"
readonly ALL="$WORK_DIR/all.txt"
readonly MANIFEST="$WORK_DIR/manifest.tsv"
readonly LISTS="$WORK_DIR/lists"

[[ -f "$MANIFEST" ]] || { echo "synapse-build-lists: no manifest.tsv in $WORK_DIR" >&2; exit 1; }

# Files with no prose value for clustering. Dropped at enumeration rather than
# parked in _unassigned, so a later re-run sweep never tries to classify a
# favicon -- _unassigned should mean "text I could not place".
#
# Kept deliberately ecosystem-neutral: an exclusion list that only knows JVM and
# web artifacts silently indexes a few thousand .pyc / .rlib / .safetensors files
# as if they were source. Grouped by what they are, so the next language is easy
# to slot in. Source formats are never listed here -- .svg, .ipynb and .csv are
# text a reader can learn from, however awkward.
readonly BINARY_RE='\.('\
'png|gif|jpg|jpeg|bmp|tif|tiff|webp|avif|ico|svgz|psd|ai|sketch|fig|'\
'mp3|m4a|wav|flac|ogg|mp4|m4v|mov|avi|mkv|webm|'\
'zip|gz|tgz|tar|bz2|xz|zst|7z|rar|'\
'jar|war|ear|class|aar|apk|whl|egg|gem|nupkg|deb|rpm|dmg|pkg|msi|'\
'o|a|obj|lib|pdb|so|dylib|dll|exe|rlib|wasm|node|pyc|pyo|pyd|beam|'\
'parquet|avro|orc|db|sqlite|sqlite3|mdb|'\
'pkl|pickle|npy|npz|h5|hdf5|onnx|pt|pth|ckpt|safetensors|gguf|bin|'\
'pdf|xls|xlsx|doc|docx|ppt|pptx|odt|ods|odp|'\
'ttf|otf|woff|woff2|eot|'\
'keystore|jks|p12|pem|crt|cer|der'\
')$'

# Generated files whose names, not extensions, identify them. A lockfile is
# thousands of lines of resolved versions with nothing to summarise, and a
# minified bundle or source map is machine output that happens to end in .js.
readonly NOISE_RE='(^|/)('\
'package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|'\
'Cargo\.lock|poetry\.lock|Pipfile\.lock|uv\.lock|Gemfile\.lock|composer\.lock|'\
'go\.sum|mix\.lock|pubspec\.lock|packages\.lock\.json|flake\.lock'\
')$|\.min\.(js|css)$|\.(js|css|ts)\.map$'

if [[ ! -s "$ALL" || "$reenumerate" == true ]]; then
    echo "--- enumerating tracked files"
    # `git ls-files` gives .gitignore exclusion for free. The `-f` test drops
    # submodule gitlinks: ls-files reports one entry per submodule, but it is a
    # directory on disk and `git hash-object` fails on it, taking the whole batch
    # down. Testing for a regular file is deliberate -- parsing .gitmodules would
    # let a stray non-file through, and synthesising a hash from `ls-files -s`
    # would leave the writer and `synapse-query.sh stale` using different
    # commands for that entry, a permanent false positive.
    # `if` rather than `[[ -f ]] && printf`: as the loop body's last statement a
    # false test makes the whole while loop exit 1, and under `set -e` that kills
    # the script -- which happens exactly when the last enumerated entry is the
    # one being skipped, e.g. a `vendor/` submodule sorting last.
    # $SYNAPSE_EXTRA_EXCLUDE_RE adds repo-specific noise (generated clients, vendored
    # trees) without editing this script. It appends to the built-in lists rather
    # than replacing them, so a repo can never accidentally lose the defaults.
    git ls-files \
        | grep -vE "$BINARY_RE" \
        | grep -vE "$NOISE_RE" \
        | grep -vE "${SYNAPSE_EXTRA_EXCLUDE_RE:-^$}" \
        | while IFS= read -r p; do
        if [[ -f "$p" ]]; then
            printf '%s\n' "$p"
        fi
    done > "$ALL"
fi

rm -rf "$LISTS"
mkdir -p "$LISTS"

node_index=0
while IFS=$'\t' read -r title include exclude; do
    [[ -n "$title" ]] || continue
    node_index=$((node_index + 1))
    slug="$(printf '%02d' "$node_index")"
    printf '%s\n' "$title" > "$LISTS/$slug.title"
    # An empty exclude column means "exclude nothing"; `^$` never matches a path.
    grep -E "$include" "$ALL" | grep -vE "${exclude:-^$}" > "$LISTS/$slug.txt" || true
    printf '%s\t%s\t%s\n' "$slug" "$(wc -l < "$LISTS/$slug.txt" | tr -d ' ')" "$title"
done < "$MANIFEST"

echo "--- coverage"
cat "$LISTS"/*.txt | LC_ALL=C sort -u > "$WORK_DIR/covered.txt"
LC_ALL=C sort "$ALL" > "$WORK_DIR/all-sorted.txt"
comm -23 "$WORK_DIR/all-sorted.txt" "$WORK_DIR/covered.txt" > "$WORK_DIR/unassigned.txt"
printf 'enumerated: %s\ncovered:    %s\nunassigned: %s\n' \
    "$(wc -l < "$WORK_DIR/all-sorted.txt" | tr -d ' ')" \
    "$(wc -l < "$WORK_DIR/covered.txt" | tr -d ' ')" \
    "$(wc -l < "$WORK_DIR/unassigned.txt" | tr -d ' ')"
