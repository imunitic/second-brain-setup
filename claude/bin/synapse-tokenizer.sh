#!/bin/bash
# Turns a raw prompt into a handful of distinctive terms for a `regexp` OR-pattern,
# entirely mechanically -- no LLM call, cheap enough to run on every turn. Built for
# the per-prompt context injection hook; see docs/synapse-graph.md's "What every
# prompt is told" section for the full mechanism this feeds.
#
# Usage: synapse-tokenizer.sh <prompt>
#   Character class: $SYNAPSE_TOKENIZER_EXTRA_CHARS, default empty -- appended onto
#     the base A-Za-z_ class. A Lisp/Clojure/Scheme repo (hyphenated identifiers
#     like `make-instance`) sets this to `-`; appending keeps it at the end of the
#     bracket expression, which is exactly where a literal `-` needs no escaping.
#   Stopwords file: ~/.claude/synapse-prompt-stopwords.conf (installed by setup.sh
#     from synapse-prompt-stopwords.conf.template; English by default, extensible
#     per that file's own header).
#
# Prints surviving terms, one per line, first-letter bracket-cased (e.g.
# `Cached_backend` -> `[Cc]ached_backend`) -- join with `|` for a regexp pattern.
# Exit codes: 0 always; empty output means nothing survived (a purely
# conversational prompt), which the caller should treat as "nothing to inject."
set -uo pipefail

PROMPT="${1:-}"
STOPWORDS="$HOME/.claude/synapse-prompt-stopwords.conf"
[ -f "$STOPWORDS" ] || STOPWORDS=/dev/null

CHARS="A-Za-z_${SYNAPSE_TOKENIZER_EXTRA_CHARS:-}"
grep -oE "[$CHARS]+" <<< "$PROMPT" \
  | grep -vxFf "$STOPWORDS" \
  | awk 'length >= 4' \
  | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- | head -8 \
  | awk '{ first = substr($0, 1, 1); rest = substr($0, 2)
           print "[" toupper(first) tolower(first) "]" rest }'
# A prompt that filters down to nothing (every word a stopword, or none survive
# length/cap) leaves grep -vxFf with zero matching lines, which grep itself
# exits 1 for -- and pipefail then makes that the whole pipeline's exit status,
# even though empty output is a legitimate, meaningful result here, not a
# failure. Force success explicitly so the documented "exit 0 always" holds.
exit 0
