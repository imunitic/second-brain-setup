#!/bin/bash
# Flags candidate clusters that own no vocabulary of their own, before anyone
# pays to author their prose. The one quality check /synapse-init never had:
# coverage was already provable by regex expansion plus `comm`, but whether a
# cluster corresponds to a *concept* was judgment, discovered only when someone
# tried to write its summary and found there was nothing to say.
#
# Usage: synapse-gate.sh --vocab <groupwords.tsv> [--all] [--top N]
#   --vocab  cluster-keyed vocabulary: `cluster <TAB> word <TAB> count`, i.e.
#            synapse-vocab.sh run with --lists. NOT the directory-keyed table --
#            see "RUN IT ON CLUSTERS" below, which is the whole reason the
#            threshold ever looked unstable.
#   --all    print every cluster with its score, not only the flagged ones.
#   --top    terms per cluster the rule looks at, default 8.
#
# Prints `cluster <TAB> rare-count <TAB> flagged|ok <TAB> top terms`, one line
# per flagged cluster -- so empty output means every cluster is differentiated,
# matching the reporting convention of `synapse-query.sh stale`/`drift`/
# `grounding`. `--all` adds the `ok` rows in the same shape rather than a
# second one, so the same field positions parse either way.
#
# THE RULE, and why it is this and not something more obvious:
#
#   rare  := df <= max(2, N/20)      # N = number of clusters, df over clusters
#   flag  := count of rare terms among the cluster's top TOP <= 1
#
# Terms rank within a cluster by raw count. Ranking by tf-idf *sum* is what
# fails: a sum follows frequency rather than rarity, and it put two known-bad
# clusters near the TOP of the list. What separates a real concept from a
# generic one is not how much distinctive vocabulary it has in total, it is
# whether it has any at all -- so the rule counts near-unique terms rather than
# weighing them.
#
# Measured against the four known-undifferentiated clusters in syrius3@master
# (46 nodes): tolerance 0 catches three with no false positives, tolerance 1
# catches all four with no false positives, tolerance 2 catches four but flags
# five good clusters as well. The `max(2, N/20)` form reduces to the constant
# that worked at that corpus size and scales with cluster count instead of
# needing recalibration per repo.
#
# RUN IT ON CLUSTERS, NOT ON MODULE GROUPS. A few dozen candidate clusters, not
# the several hundred directory groups that form the orientation evidence.
# Document frequency across 500 groups means something entirely different from
# document frequency across 46 clusters, and feeding the wrong table in is what
# made the threshold look like it needed tuning.
#
# KNOWN LIMIT, deliberately unfixed: the rule cannot distinguish "owns no
# distinctive vocabulary" from "produced no vocabulary". Both present as zero
# rare terms. In a single-language repo the ambiguity cannot arise. In a mixed
# repo, a cluster whose code is in a language with no grammar is flagged as
# undifferentiated when it should be left alone -- so treat a flag on such a
# cluster as "look at it", which is all a flag ever means here. Whatever
# eventually addresses mixed repos has to give this rule a parseable-fraction
# signal to tell the two cases apart.
#
# Exit codes:
#   0 - ran. Flagged clusters, if any, are on stdout; a flag is advice to
#       re-cluster or disperse, never a hard stop, so this is 0 either way.
#   1 - could not run (unreadable or empty vocabulary file)
#   2 - usage error
set -uo pipefail

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

VOCAB=""
TOP=8
ALL=false
while [ $# -gt 0 ]; do
    case "$1" in
        --vocab) VOCAB="${2:-}"; shift 2 || usage ;;
        --top)   TOP="${2:-}";   shift 2 || usage ;;
        --all)   ALL=true; shift ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
[ -n "$VOCAB" ] || usage
case "$TOP" in ''|*[!0-9]*) usage ;; esac
[ "$TOP" -ge 1 ] || usage
[ -f "$VOCAB" ] || { echo "synapse-gate: no such vocabulary file: $VOCAB" >&2; exit 1; }
[ -s "$VOCAB" ] || {
    echo "synapse-gate: $VOCAB is empty -- nothing was tagged, so cluster quality cannot be judged" >&2
    exit 1; }

# One pass, entirely in awk. Every count is already in the file; there is no
# per-cluster subprocess and nothing re-reads the repo.
LC_ALL=C awk -F'\t' -v TOP="$TOP" -v ALL="$ALL" '
  NF < 3 { next }
  {
    cl = $1; w = $2; n = $3 + 0
    if (!(cl in seen)) { seen[cl] = 1; order[++nc] = cl }
    key = cl SUBSEP w
    # First sighting owns the bookkeeping: df counts CLUSTERS containing the
    # word, so a repeated pair must not increment it twice, and the term list
    # must not carry the same word twice into the top-N selection.
    if (!(key in cnt)) { df[w]++; words[cl] = words[cl] SUBSEP w; cnt[key] = n }
    else if (n > cnt[key]) cnt[key] = n
  }
  END {
    if (nc == 0) exit 0
    # The threshold scales with cluster count and floors at the constant that
    # was measured to work: N/20 is 2 for anything up to 40 clusters.
    rare_max = int(nc / 20)
    if (rare_max < 2) rare_max = 2

    for (i = 1; i <= nc; i++) {
      cl = order[i]
      nw = split(words[cl], ws, SUBSEP)

      # Top TOP terms of this cluster by count, by selection rather than by
      # sorting: TOP is 8 and a cluster has thousands of terms, so a full sort
      # per cluster is work with no answer attached to it.
      ntop = 0
      delete taken
      for (r = 1; r <= TOP; r++) {
        best = ""; bestn = -1
        for (j = 1; j <= nw; j++) {
          w = ws[j]
          if (w == "" || (w in taken)) continue
          n = cnt[cl SUBSEP w]
          # Ties broken by name so the output is reproducible run to run.
          if (n > bestn || (n == bestn && w < best)) { best = w; bestn = n }
        }
        if (best == "") break
        taken[best] = 1
        top[++ntop] = best
      }

      rare = 0; line = ""
      for (r = 1; r <= ntop; r++) {
        w = top[r]
        if (df[w] <= rare_max) rare++
        line = line (line == "" ? "" : " ") w
      }

      flagged = (rare <= 1)
      if (flagged || ALL == "true")
        printf "%s\t%d\t%s\t%s\n", cl, rare, flagged ? "flagged" : "ok", line
    }
  }
' "$VOCAB"
exit 0
