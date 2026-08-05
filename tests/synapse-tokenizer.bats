#!/usr/bin/env bats
# Tests claude/bin/synapse-tokenizer.sh -- pure text processing, no network,
# no vault. Covers the two real bugs found while building it (see sb-004):
# GNU-only sed \U/\L escapes breaking bracket-casing under BSD sed, and
# grep -w wrongly dropping a whole hyphenated token when the character
# class is extended with a non-word character.

load 'test_helper'

TOKENIZER="$REPO_ROOT/claude/bin/synapse-tokenizer.sh"

setup() {
  common_setup
  cp "$REPO_ROOT/claude/synapse-prompt-stopwords.conf.template" \
    "$HOME/.claude/synapse-prompt-stopwords.conf"
}

teardown() {
  common_teardown
}

@test "ordinary sentence: stopwords filtered, distinctive terms survive, bracket-cased" {
  run "$TOKENIZER" "how does Cached_backend invalidate results"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[Cc]ached_backend"* ]]
  [[ "$output" == *"[Ii]nvalidate"* ]]
  [[ "$output" != *"how"* ]]
  [[ "$output" != *"does"* ]]
}

@test "purely conversational prompt: every word is a stopword, output empty" {
  run "$TOKENIZER" "how are you doing"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "short words below the minimum length are dropped even when not stopwords" {
  run "$TOKENIZER" "the zzz fix"
  [ "$status" -eq 0 ]
  [[ "$output" != *"zzz"* ]]
}

@test "long input: term count is capped, not unbounded" {
  # 20 distinct 5+ char non-stopword tokens -- well over the cap.
  prompt="alpha bravo charlie delta echo foxtrot golfer hotel indigo julia kilogram lunar mongoose november octopus papaya quokka rooster sierra tundra umbrella"
  run "$TOKENIZER" "$prompt"
  [ "$status" -eq 0 ]
  n="$(printf '%s\n' "$output" | grep -c .)"
  [ "$n" -le 8 ]
}

@test "default character class: hyphen splits a compound word into separate tokens" {
  run "$TOKENIZER" "check the with-open-stream helper"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[Oo]pen"* ]]
  [[ "$output" != *"with-open-stream"* ]]
}

@test "SYNAPSE_TOKENIZER_EXTRA_CHARS=-: hyphenated identifier survives whole, stopword still filtered" {
  # Regression test for the real -w-vs--x bug: with '-' in the character class,
  # "with-open-stream" is one token containing the embedded stopword "with" --
  # a word-boundary stopword match wrongly dropped the whole token; whole-line
  # matching must not, since "with-open-stream" itself is never a stopword line.
  SYNAPSE_TOKENIZER_EXTRA_CHARS="-" run "$TOKENIZER" "check the with-open-stream helper"
  [ "$status" -eq 0 ]
  [[ "$output" == *"with-open-stream"* || "$output" == *"[Ww]ith-open-stream"* ]]
}

@test "SYNAPSE_TOKENIZER_EXTRA_CHARS=-: a real stopword is still dropped, extended class or not" {
  SYNAPSE_TOKENIZER_EXTRA_CHARS="-" run "$TOKENIZER" "please check the helper function"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[Pp]lease"* ]]
}

@test "no stopwords file installed: falls back to no filtering rather than failing" {
  rm -f "$HOME/.claude/synapse-prompt-stopwords.conf"
  run "$TOKENIZER" "please check the helper"
  [ "$status" -eq 0 ]
  [[ -n "$output" ]]
}
