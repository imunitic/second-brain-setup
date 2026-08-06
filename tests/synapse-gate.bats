#!/usr/bin/env bats
# Tests claude/bin/synapse-gate.sh -- the cluster-quality gate that flags a
# candidate cluster owning no vocabulary of its own before anyone pays to author
# its prose.
#
# No repo, no tree-sitter, no fakes: the gate reads a cluster-keyed vocabulary
# table and applies arithmetic to it, so every test here writes that table
# directly. That is the point of the seam -- what the gate decides is separable
# from how the counts were obtained.

load 'test_helper'

SCRIPT="$REPO_ROOT/claude/bin/synapse-gate.sh"

setup() {
  common_setup
  VOCAB="$TEST_HOME/groupwords.tsv"
  : > "$VOCAB"
}

teardown() {
  common_teardown
}

# One cluster's terms, highest count first.
cluster() { # cluster <name> <word>...
  local name="$1"; shift
  local n=$(( $# + 10 )) w
  for w in "$@"; do
    printf '%s\t%s\t%s\n' "$name" "$w" "$n" >> "$VOCAB"
    n=$(( n - 1 ))
  done
}

# Three differentiated clusters sharing a common tail, plus one built entirely
# from that tail -- the shape the four undifferentiated syrius3 clusters had.
write_four_clusters() {
  cluster Billing  invoice dunning description identifier bundle resource
  cluster Shipping parcel carrier  description identifier bundle resource
  cluster Pricing  tariff premium  description identifier bundle resource
  cluster Generic  description identifier bundle resource
}

@test "a cluster whose top terms are all corpus-common is flagged" {
  write_four_clusters

  run "$SCRIPT" --vocab "$VOCAB"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output" | tr -d ' ')" -eq 1 ]
  [[ "$output" == Generic* ]]
  [[ "$output" == *"flagged"* ]]
}

@test "the differentiated clusters are not flagged" {
  write_four_clusters

  run "$SCRIPT" --vocab "$VOCAB"
  [ "$status" -eq 0 ]
  ! grep -q '^Billing' <<< "$output"
  ! grep -q '^Shipping' <<< "$output"
  ! grep -q '^Pricing' <<< "$output"
}

@test "empty output means every cluster is differentiated" {
  # The reporting convention the rest of the toolkit uses: a clean run says
  # nothing rather than saying 'clean' on every line.
  cluster Billing  invoice dunning ledger
  cluster Shipping parcel carrier manifest
  cluster Pricing  tariff premium discount

  run "$SCRIPT" --vocab "$VOCAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--all reports every cluster in the same shape, with a verdict column" {
  write_four_clusters

  run "$SCRIPT" --vocab "$VOCAB" --all
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output" | tr -d ' ')" -eq 4 ]
  [ "$(awk -F'\t' '$3 == "ok"' <<< "$output" | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(awk -F'\t' '$3 == "flagged"' <<< "$output" | wc -l | tr -d ' ')" -eq 1 ]
  # Same field positions either way, so one parser reads both modes.
  [ "$(awk -F'\t' 'NF != 4' <<< "$output" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "one rare term is still flagged; two is not" {
  # The measured tolerance. Against the four known-bad syrius3 clusters,
  # tolerance 0 caught three, 1 caught all four with no false positives, and 2
  # caught four but flagged five good clusters too. This pins the boundary in
  # both directions, which a test asserting only the flag would not.
  # `description` and `identifier` are in every cluster, so only the leading
  # terms are rare -- one for OneRare, two for TwoRare.
  cluster Billing  invoice dunning description identifier
  cluster Shipping parcel carrier  description identifier
  cluster Pricing  tariff premium  description identifier
  cluster OneRare  solitary description identifier
  cluster TwoRare  alpha beta description identifier

  run "$SCRIPT" --vocab "$VOCAB"
  [ "$status" -eq 0 ]
  grep -q '^OneRare' <<< "$output"
  ! grep -q '^TwoRare' <<< "$output"
}

@test "rarity is document frequency across clusters, not frequency within one" {
  # The failure mode the rule exists to avoid: ranking by tf-idf *sum* follows
  # frequency rather than rarity and put two known-bad clusters near the top.
  # Here the generic cluster has by far the biggest counts, and must still be
  # flagged -- a size-weighted rule would rank it as the healthiest one.
  cluster Billing  invoice dunning description identifier
  cluster Shipping parcel carrier  description identifier
  cluster Pricing  tariff premium  description identifier
  printf 'Huge\tdescription\t99999\n' >> "$VOCAB"
  printf 'Huge\tidentifier\t88888\n' >> "$VOCAB"

  run "$SCRIPT" --vocab "$VOCAB"
  [ "$status" -eq 0 ]
  grep -q '^Huge' <<< "$output"
}

@test "the rare threshold scales with cluster count, and floors at 2" {
  # max(2, N/20): at 60 clusters the threshold is 3, so a term shared by three
  # of them still counts as rare. Below 40 clusters it is the constant 2 that
  # was measured to work, so nothing needs recalibrating on a small repo.
  local i
  for i in $(seq 1 60); do
    # Every cluster gets a term shared by exactly three clusters, plus filler
    # shared by all sixty.
    cluster "C$i" "trio$(( (i - 1) / 3 ))" common alpha beta
  done

  run "$SCRIPT" --vocab "$VOCAB" --all
  [ "$status" -eq 0 ]
  # df(trioK) == 3 <= 60/20, so each cluster has exactly one rare term and is
  # flagged at tolerance 1. With the floor-only rule (threshold 2) df 3 would
  # not be rare and every cluster would score 0 -- also flagged, so assert the
  # score, which is what actually distinguishes the two.
  [ "$(awk -F'\t' '$2 == 1' <<< "$output" | wc -l | tr -d ' ')" -eq 60 ]
}

@test "--top changes how many terms the rule looks at" {
  # A cluster whose only distinctive terms sit below the cut is flagged at a
  # small --top and not at a large one. Pins that the window is real rather
  # than a value nothing reads.
  cluster Billing  description identifier bundle resource invoice dunning
  cluster Shipping description identifier bundle resource parcel carrier
  cluster Pricing  description identifier bundle resource tariff premium

  run "$SCRIPT" --vocab "$VOCAB" --top 4
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output" | tr -d ' ')" -eq 3 ]

  run "$SCRIPT" --vocab "$VOCAB" --top 6
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a repeated cluster/word pair counts once toward document frequency" {
  # Two nodes claiming the same file is legitimate, so synapse-vocab.sh can
  # emit a pair more than once. Double-counting it would inflate df and make a
  # distinctive term look corpus-common.
  # Three clusters, so `description` (df 3) is not rare and Billing's two rare
  # terms are exactly `invoice` and `dunning`. Counting the repeat would push
  # df(invoice) to 3, making it not rare and dropping Billing to one rare term
  # -- i.e. flagging a perfectly good cluster.
  cluster Billing  invoice dunning description
  cluster Shipping parcel carrier  description
  cluster Pricing  tariff premium  description
  printf 'Billing\tinvoice\t40\n' >> "$VOCAB"
  printf 'Billing\tinvoice\t40\n' >> "$VOCAB"

  run "$SCRIPT" --vocab "$VOCAB" --all
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "Billing" { print $2 }' <<< "$output")" = "2" ]
  # And it appears once in the term list, not three times.
  [ "$(awk -F'\t' '$1 == "Billing" { print $4 }' <<< "$output" | tr ' ' '\n' | grep -c '^invoice$')" -eq 1 ]
}

@test "output is reproducible: ties among equal counts break by name" {
  cluster Billing  alpha bravo charlie delta
  cluster Shipping alpha bravo charlie delta
  printf 'Tied\tzulu\t5\nTied\tyankee\t5\nTied\txray\t5\n' >> "$VOCAB"

  run "$SCRIPT" --vocab "$VOCAB" --all
  local first="$output"
  run "$SCRIPT" --vocab "$VOCAB" --all
  [ "$output" = "$first" ]
  [ "$(awk -F'\t' '$1 == "Tied" { print $4 }' <<< "$output")" = "xray yankee zulu" ]
}

@test "an empty or missing vocabulary file exits 1 rather than reporting all clear" {
  # The dangerous silent case: nothing was tagged, so no cluster has any
  # vocabulary, and a rule that just counted rare terms would flag every one of
  # them -- or, printing nothing, would read as a clean bill of health.
  run "$SCRIPT" --vocab "$VOCAB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty"* ]]

  run "$SCRIPT" --vocab "$TEST_HOME/nope.tsv"
  [ "$status" -eq 1 ]
}

@test "usage errors exit 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" --vocab "$VOCAB" --top zero
  [ "$status" -eq 2 ]
  run "$SCRIPT" --nope
  [ "$status" -eq 2 ]
}
