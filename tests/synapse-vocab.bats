#!/usr/bin/env bats
# Tests claude/bin/synapse-vocab.sh -- the pass that reduces a whole repo to
# `group <TAB> word <TAB> count` so the clustering step of /synapse-init can
# decide what a subsystem is about from symbol names instead of source lines.
#
# tree-sitter is the fake in tests/fixtures/fake-bin: it emits FAKE_NAME for
# every .ml/.java/.py file plus one tag per `symbol:<Name>` line in the file, so
# a fixture's vocabulary is authored as ordinary file content. Everything about
# the reduction -- CamelCase and snake_case splitting, stopwording, the group
# key, the counts -- is therefore asserted against symbols the test chose.

load 'test_helper'

SCRIPT="$REPO_ROOT/claude/bin/synapse-vocab.sh"

setup() {
  common_setup
  mkdir -p "$HOME/.claude/bin"
  cp "$REPO_ROOT/claude/bin/synapse-tags.sh" "$HOME/.claude/bin/synapse-tags.sh"
  chmod +x "$HOME/.claude/bin/synapse-tags.sh"
  # Every extension the fake knows about, so the script's own registry gate is
  # not what a vocabulary assertion is really testing.
  printf '%s' '{"java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
                "py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
                "ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
  OUT="$TEST_HOME/out"
}

teardown() {
  common_teardown
}

# A file with the given symbols, one `symbol:` line each. The body is otherwise
# irrelevant: the fake reads only those lines.
src() { # src <repo-relative path> <symbol>...
  local path="$REPO/$1"; shift
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local s
  for s in "$@"; do printf 'symbol:%s\n' "$s" >> "$path"; done
}

# Two modules with deliberately disjoint domain vocabulary, plus one term
# ("Shared") every module uses -- the corpus-common case the quality gate later
# has to be able to see.
make_two_module_repo() {
  git init -q "$REPO"
  src billing/src/InvoiceCalculator.java InvoiceCalculator SharedRegistry
  src billing/src/DunningSchedule.java   DunningSchedule    SharedRegistry
  src shipping/src/ParcelRouter.java     ParcelRouter       SharedRegistry
  src shipping/src/CarrierManifest.java  CarrierManifest    SharedRegistry
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
}

run_vocab() {
  PATH="$FAKE_BIN:$PATH" "$SCRIPT" --repo "$REPO" --out "$OUT" "$@"
}

# The count for one group/word pair, or empty when the pair is absent.
count_of() { # count_of <group> <word>
  awk -F'\t' -v g="$1" -v w="$2" '$1 == g && $2 == w { print $3 }' "$OUT/groupwords.tsv"
}

@test "two modules with different symbols yield disjoint top terms" {
  make_two_module_repo

  run run_vocab
  [ "$status" -eq 0 ]

  # Each module's own vocabulary, and only its own.
  [ -n "$(count_of billing/src invoice)" ]
  [ -n "$(count_of billing/src dunning)" ]
  [ -z "$(count_of billing/src parcel)" ]
  [ -z "$(count_of billing/src carrier)" ]

  [ -n "$(count_of shipping/src parcel)" ]
  [ -n "$(count_of shipping/src carrier)" ]
  [ -z "$(count_of shipping/src invoice)" ]
}

@test "a term used by every module is present in every group, so its df is visible" {
  # Not scored here: synapse-vocab.sh counts, and the quality gate is what turns
  # a high document frequency into "this cluster owns no vocabulary". The gate
  # can only do that if the term is actually recorded per group rather than
  # filtered out as noise on the way through.
  make_two_module_repo

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(count_of billing/src shared)" = "2" ]
  [ "$(count_of shipping/src shared)" = "2" ]
  [ "$(awk -F'\t' '$2 == "registry"' "$OUT/groupwords.tsv" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "CamelCase and snake_case split into words; a run of capitals stays whole" {
  git init -q "$REPO"
  src core/src/A.java getUserName premium_rate_table HTTPServer
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -n "$(count_of core/src user)" ]
  [ -n "$(count_of core/src name)" ]
  [ -n "$(count_of core/src premium)" ]
  [ -n "$(count_of core/src rate)" ]
  [ -n "$(count_of core/src table)" ]
  # `get` is under four characters, so it never survives regardless.
  [ -z "$(count_of core/src get)" ]
  # An acronym run absorbs what follows it -- documented behaviour, not a bug to
  # fix silently later: the alternative needs lookahead, which awk has no form of.
  [ -n "$(count_of core/src httpserver)" ]
}

@test "stopwords come from the tokenizer's own list, and short words are dropped" {
  cp "$REPO_ROOT/claude/synapse-prompt-stopwords.conf.template" \
    "$HOME/.claude/synapse-prompt-stopwords.conf"
  git init -q "$REPO"
  # `Another` and `Because` are ordinary English function words in that list and
  # would otherwise be perfectly good-looking domain terms.
  src core/src/A.java AnotherThing BecauseInvoice Fee
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -z "$(count_of core/src another)" ]
  [ -z "$(count_of core/src because)" ]
  [ -z "$(count_of core/src fee)" ]      # three characters
  [ -n "$(count_of core/src thing)" ]
  [ -n "$(count_of core/src invoice)" ]
}

@test "counts.tsv counts every tracked file, not only the ones with a grammar" {
  # Coverage and vocabulary are separate axes: a group's size is what the model
  # weighs when clustering, and a module that is mostly XML is still that big.
  git init -q "$REPO"
  src core/src/A.java Alpha
  printf 'x\n' > "$REPO/core/src/b.xml"
  printf 'y\n' > "$REPO/core/src/c.xml"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "core/src" { print $2 }' "$OUT/counts.tsv")" = "3" ]
}

@test "a repo-root file groups as (repo root) rather than vanishing" {
  git init -q "$REPO"
  src core/src/A.java Alpha
  printf 'readme\n' > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "(repo root)" { print $2 }' "$OUT/counts.tsv")" = "1" ]
}

@test "--depth changes the group key, and counts.tsv keys agree with groupwords.tsv" {
  # The two files keyed differently is the failure that makes a group look like
  # it has vocabulary but no files, or the reverse -- so the grouping rule is
  # shared textually and this pins that it stays shared.
  git init -q "$REPO"
  src alpha/one/deep/A.java Invoice
  src alpha/two/deep/B.java Parcel
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab --depth 1
  [ "$status" -eq 0 ]
  [ -n "$(count_of alpha invoice)" ]
  [ -n "$(count_of alpha parcel)" ]

  run run_vocab --depth 2
  [ "$status" -eq 0 ]
  [ -n "$(count_of alpha/one invoice)" ]
  [ -z "$(count_of alpha/one parcel)" ]

  # Every group named in groupwords.tsv exists in counts.tsv.
  run bash -c "cut -f1 '$OUT/groupwords.tsv' | sort -u > '$TEST_HOME/gw-keys'
               cut -f1 '$OUT/counts.tsv'     | sort -u > '$TEST_HOME/c-keys'
               comm -23 '$TEST_HOME/gw-keys' '$TEST_HOME/c-keys'"
  [ -z "$output" ]
}

@test "an extension with no grammar is warned once for the whole run, not once per chunk" {
  # The chunking is invisible to a caller, so its granularity must not leak into
  # the warnings: with --chunk 1 there is one invocation per file, and a
  # per-invocation warning would print four times instead of once.
  git init -q "$REPO"
  src core/src/A.java Alpha
  src core/src/B.java Beta
  printf 'x\n' > "$REPO/core/src/c.zzz"
  printf 'y\n' > "$REPO/core/src/d.zzz"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  # .zzz is not a code extension, so make it one the script will try: the point
  # is the dedup, and any extension in CODE_RE with no registry entry shows it.
  mv "$REPO/core/src/c.zzz" "$REPO/core/src/c.rb"
  mv "$REPO/core/src/d.zzz" "$REPO/core/src/d.rb"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m "rb"

  run run_vocab --chunk 1
  [ "$status" -eq 0 ]
  [ "$(grep -c 'no grammar registered for .rb' <<< "$output")" -eq 1 ]
  # And the files that did have one still produced vocabulary.
  [ -n "$(count_of core/src alpha)" ]
}

@test "nothing with a usable grammar: empty groupwords.tsv and exit 0, not an error" {
  # The signal to fall back to synapse-orientation. An exit 1 here would read as
  # "the script is broken" in a repo that is simply written in a language with
  # no grammar installed, which is a supported state.
  git init -q "$REPO"
  mkdir -p "$REPO/core/src"
  printf 'x\n' > "$REPO/core/src/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -f "$OUT/groupwords.tsv" ]
  [ ! -s "$OUT/groupwords.tsv" ]
  [[ "$output" == *"synapse-orientation"* ]]
}

@test "synapse-ignore-files.conf excludes a path from the evidence as well as the graph" {
  # Vendored and generated trees would otherwise dominate the vocabulary of
  # whatever group they sit in, and a path excluded from the graph has no node
  # for that vocabulary to describe.
  git init -q "$REPO"
  src core/src/A.java Alpha
  src vendor/lib/B.java Vendored
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -n "$(count_of vendor/lib vendored)" ]

  printf '(^|/)vendor/\n' > "$HOME/.claude/synapse-ignore-files.conf"
  run run_vocab
  [ "$status" -eq 0 ]
  [ -z "$(count_of vendor/lib vendored)" ]
  [ -z "$(awk -F'\t' '$1 == "vendor/lib"' "$OUT/counts.tsv")" ]
  [ -n "$(count_of core/src alpha)" ]
}

@test "raw tags are never written to disk, only the reduction" {
  # 98k code files produce ~942 MB of tags against 6.9 MB of vocabulary, so the
  # worker must stream into the reduction. Asserted structurally: the tags-sh
  # invocation has to be a pipe source, never a redirect into a file.
  run grep -cE 'tags_sh" --paths "\$chunk" 2>"\$out.err" \\$' "$SCRIPT"
  [ "$output" = "1" ]
  run grep -c 'awk -F' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "no per-file subprocess anywhere in the repo-scale path" {
  # The trap this whole design exists to avoid, and one a five-file fixture can
  # never detect by timing: a `basename`/`wc`/`stat` per path cost minutes where
  # a batched equivalent cost seconds. basename appears exactly once, per CHUNK.
  [ "$(grep -c 'basename' "$SCRIPT")" -eq 1 ]
  [ "$(grep -c 'wc -c' "$SCRIPT")" -eq 0 ]
}

@test "defaults to the work dir when --out is omitted" {
  make_two_module_repo
  cp "$REPO_ROOT/claude/bin/synapse-identity.sh" "$HOME/.claude/bin/synapse-identity.sh"

  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --repo "$REPO"
  [ "$status" -eq 0 ]
  [ -s "$HOME/.claude/synapse-work/$(repo_name)/groupwords.tsv" ]
  [ -s "$HOME/.claude/synapse-work/$(repo_name)/counts.tsv" ]
}

@test "outside a git repo: exits 1 with a message, writes nothing" {
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --repo "$TEST_HOME" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repo"* ]]
  [ ! -f "$OUT/groupwords.tsv" ]
}

@test "a bad flag or a non-numeric depth is a usage error, exit 2" {
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --nope
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --depth two
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SCRIPT" --depth 0
  [ "$status" -eq 2 ]
}
