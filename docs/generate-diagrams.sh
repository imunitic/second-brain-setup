#!/bin/bash
# Renders every docs/diagrams/*.mmd to a same-named .png with mermaid-cli, and
# records the source hash so a stale render is a test failure rather than a
# picture that quietly disagrees with the text around it.
#
# Usage: generate-diagrams.sh            render every diagram whose source changed
#        generate-diagrams.sh --all      re-render everything, changed or not
#        generate-diagrams.sh --check    exit 1 if any .png is missing or stale
#        generate-diagrams.sh --help
#
# Why a PNG at all, when GitHub renders ```mermaid fences natively: the docs are
# also read in Markview and other plain Markdown viewers, and a fence shows up
# there as a wall of source. A linked image works everywhere.
#
# Why hash the source instead of comparing the .png: mermaid-cli output is not
# byte-reproducible across versions, fonts or platforms, so a byte comparison
# would fail for reasons that have nothing to do with the diagram. The recorded
# sha256 of each .mmd answers the only question --check needs to ask -- was this
# .png produced from this source.
#
# Exit codes:
#   0 - rendered (or, for --check, everything is current)
#   1 - a render failed, mmdc is missing, or --check found something stale
#   2 - usage error
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/diagrams"
STAMPS="$DIR/.rendered"

usage() {
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

MODE="changed"
case "${1:-}" in
    "")        MODE="changed" ;;
    --all)     MODE="all" ;;
    --check)   MODE="check" ;;
    -h|--help) usage 0 ;;
    *)         usage ;;
esac

if command -v shasum >/dev/null; then
    sha256() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null; then
    sha256() { sha256sum | cut -d' ' -f1; }
else
    echo "generate-diagrams: no shasum or sha256sum" >&2
    exit 1
fi

# Recorded hash for one diagram, or empty when it has never been rendered.
stamp_of() { # stamp_of <name>
    [ -f "$STAMPS" ] || return 0
    awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$STAMPS"
}

shopt -s nullglob
SOURCES=("$DIR"/*.mmd)
if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "generate-diagrams: no .mmd sources in $DIR" >&2
    exit 1
fi

STALE=()
for src in "${SOURCES[@]}"; do
    name="$(basename "$src" .mmd)"
    want="$(sha256 < "$src")"
    if [ ! -f "$DIR/$name.png" ]; then
        STALE+=("$name (no .png)")
    elif [ "$(stamp_of "$name")" != "$want" ]; then
        STALE+=("$name (source changed since it was rendered)")
    fi
done

if [ "$MODE" = "check" ]; then
    if [ ${#STALE[@]} -gt 0 ]; then
        echo "generate-diagrams: ${#STALE[@]} diagram(s) out of date:" >&2
        printf '  %s\n' "${STALE[@]}" >&2
        echo "  run docs/generate-diagrams.sh" >&2
        exit 1
    fi
    exit 0
fi

command -v mmdc >/dev/null || {
    echo "generate-diagrams: mmdc not found (npm i -g @mermaid-js/mermaid-cli)" >&2
    exit 1
}

# A white background rather than transparent: these are linked from Markdown and
# read in viewers with their own theme, and mermaid's default dark-on-transparent
# is unreadable against a dark one.
rendered=0
for src in "${SOURCES[@]}"; do
    name="$(basename "$src" .mmd)"
    want="$(sha256 < "$src")"
    if [ "$MODE" = "changed" ] && [ -f "$DIR/$name.png" ] && [ "$(stamp_of "$name")" = "$want" ]; then
        continue
    fi
    mmdc --quiet -i "$src" -o "$DIR/$name.png" -b white -s 2 >/dev/null
    # Rewrite this diagram's stamp, leaving the others alone.
    if [ -f "$STAMPS" ]; then
        awk -F'\t' -v n="$name" '$1 != n' "$STAMPS" > "$STAMPS.tmp" || true
    else
        : > "$STAMPS.tmp"
    fi
    printf '%s\t%s\n' "$name" "$want" >> "$STAMPS.tmp"
    LC_ALL=C sort "$STAMPS.tmp" > "$STAMPS"
    rm -f "$STAMPS.tmp"
    echo "rendered $name.png"
    rendered=$((rendered + 1))
done

[ "$rendered" -gt 0 ] || echo "every diagram already current"
