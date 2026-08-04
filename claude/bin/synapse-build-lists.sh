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
# Prints enumerated/covered/unassigned counts, so a bad pattern shows up as a
# number rather than a silent gap. $SYNAPSE_EXTRA_EXCLUDE_RE appends repo-specific
# noise to the built-in exclusions.
#
# Exit codes: 0 ok, 1 could not run, 2 usage error
set -euo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

reenumerate=false
case "${1:-}" in
    "") ;;
    --reenumerate) reenumerate=true ;;
    -h|--help) usage 0 ;;
    *) usage ;;
esac

command -v git >/dev/null || { echo "synapse-build-lists: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-build-lists: not inside a git repo" >&2; exit 1; }
REPO_NAME="$(basename "$REPO_ROOT")"

# Not $PWD: the repo is resolved from $PWD, so a $PWD default would write the
# enumeration and lists into the user's checkout. Per repo, so a re-run finds the
# previous manifest.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
mkdir -p "$WORK_DIR"
readonly ALL="$WORK_DIR/all.txt"
readonly MANIFEST="$WORK_DIR/manifest.tsv"
readonly LISTS="$WORK_DIR/lists"

[[ -f "$MANIFEST" ]] || { echo "synapse-build-lists: no manifest.tsv in $WORK_DIR" >&2; exit 1; }

# Dropped at enumeration, so _unassigned means "text I could not place". Grouped
# by what a file is rather than by ecosystem, so adding a language is a one-line
# change. Source formats never belong here.
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
    git ls-files \
        | grep -vE "$BINARY_RE" \
        | grep -vE "$NOISE_RE" \
        | grep -vE "${SYNAPSE_EXTRA_EXCLUDE_RE:-^$}" \
        | while IFS= read -r p; do
        # -f drops submodule gitlinks: one ls-files entry each, but a directory on
        # disk, and `git hash-object` fails the whole batch on one. Written as an
        # `if` because as the body's last statement a false `[[ -f ]] && printf`
        # makes the loop exit 1, which under `set -e` kills the script.
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
# LC_ALL=C on comm as well as on the sorts. comm verifies its inputs against the
# *ambient* collation, and under a UTF-8 locale it silently reports every line as
# unique once uppercase filenames are involved (README.md sorts before crates/ in C
# but not in en_US.UTF-8) -- which would make the coverage report claim nothing is
# covered, with no warning at all.
LC_ALL=C comm -23 "$WORK_DIR/all-sorted.txt" "$WORK_DIR/covered.txt" > "$WORK_DIR/unassigned.txt"
printf 'enumerated: %s\ncovered:    %s\nunassigned: %s\n' \
    "$(wc -l < "$WORK_DIR/all-sorted.txt" | tr -d ' ')" \
    "$(wc -l < "$WORK_DIR/covered.txt" | tr -d ' ')" \
    "$(wc -l < "$WORK_DIR/unassigned.txt" | tr -d ' ')"
