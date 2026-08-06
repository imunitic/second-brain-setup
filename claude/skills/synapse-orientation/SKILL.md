---
name: synapse-orientation
description: How to work out where meaning lives in a codebase you have not seen before — first mechanically, from the repo's own symbol vocabulary, and where no grammar exists, by four questions in order with the cheap commands that answer each. Includes tree-sitter grammar discovery. Use when clustering a repo into Synapse graph nodes for the first time, when re-deriving a node's premises in /synapse-rebuild's re-orient class, or any time you need to orient in an unfamiliar tree before making claims about it.
---

# Orienting in an unfamiliar repo

Loaded by `/synapse-init` at its orientation step, and by `/synapse-rebuild` when a node lands in
the *re-orient* class and its premises have to be re-derived rather than patched. Useful on its own
terms too: nothing here is Synapse-specific except what you do with the answers.

It is a skill rather than a section inside either caller because it is technique, not procedure —
how to find where meaning lives in a tree you have never seen. Both callers need exactly the same
technique, and a copy in each is how the two start giving different advice.

The goal is not a summary of every file; it is learning *where meaning lives in this particular
tree* well enough to cluster it and then write about it.

## Start with the vocabulary — it is mechanical, and it is most of the answer

```
synapse-vocab.sh                    # writes groupwords.tsv + counts.tsv into $SYNAPSE_WORK_DIR
```

One command derives what used to be an exploration. It tags every file that has a grammar, splits
symbol names on CamelCase and snake_case, drops stopwords, and aggregates per directory group:

- `counts.tsv` — `group ⇥ file count`, biggest first. **This is question 1, already answered.**
- `groupwords.tsv` — `group ⇥ word ⇥ count`. **This is question 4, for the whole repo, unsampled.**

Measured: the whole of syrius3 (125,351 files, 98k of them code) takes ~51 seconds, and clusters
derived from the result expanded to 99.91% coverage. Read these two files and cluster from them.
Reading is free; only what you print costs, so collapse to a few dozen lines before reading any
source at all.

**What the table cannot tell you** is which words are *distinctive* rather than merely frequent —
that judgment is yours, and it is the actual work. A word appearing in every group is background;
a word appearing in two is a concept. Scan across groups, not down one.

**An empty `groupwords.tsv` is a legitimate answer**, not a failure: no file in this tree had a
usable grammar. `synapse-vocab.sh` says so on stderr and exits 0. That is the case the four
questions below exist for.

## When there is no usable grammar — and as a complement when there is

Four questions, in order. They are language-agnostic; how you answer each one is not, and deducing
that on the spot is the work. With a vocabulary table in hand, 1 and 4 are already answered and 2
and 3 are still worth asking — question 3 in particular is invisible to the vocabulary, because it
is about the gap between what the code calls itself and what the *directory* calls it:

1. **Where is the weight?** Group paths by module/directory and count. Tells you which
   subsystems are large enough to deserve a node and which must be grouped with a neighbour.
2. **What kind of artifact dominates?** Group by extension and count, per candidate cluster.
   This is the cheapest source of genuine surprise — a cluster that is 60% JSON or `.bpmn` or
   `.sql` is telling you something no module name will.
3. **What does the code call itself, versus what the directory calls it?** Derive the code's own
   namespace roots (Java/Kotlin packages, Rust `mod`/crate paths, Go packages, Python modules,
   OCaml library names, TS path aliases) and compare them with the directory names. **Divergences
   here are the highest-value findings in the whole build** and they are invisible from the
   filesystem: a module named one thing whose code is uniformly named another means every later
   search for the wrong term returns nothing.
4. **What are the domain's verbs?** The exported/public symbol names — they read as the
   vocabulary of the domain, and clusters of related names (a state machine, a configuration
   family) are what a node's prose should be about.

**Answer these with aggregate shell over the path lists, not by reading files.** Reading is
internal and free; only what you print costs tokens, so a 15,000-file cluster should collapse to
a few dozen lines before you read anything. Then let `synapse-rank.sh` pick which 2–4 files per
node are worth actually reading — see "Choosing what to read" below.

**Do not sample, and do not invent a sampling rule.** An earlier version of this skill said
`synapse-tags.sh` took one file per invocation and so could not be run over a whole cluster,
and told you to pick a sampling rule and defend it. That is obsolete: `synapse-tags.sh --paths`
tags a whole list in one invocation, which measured 33× on 200 files, and `synapse-vocab.sh`
above uses it to cover an entire repository in under a minute. Sampling existed only to bound a
cost that no longer exists, and every fixed rule was biased in a way that had to be chosen
deliberately — alphabetical is an accident, largest-file favours generated code and god-classes,
most-referenced needs the full scan you were avoiding. If you find yourself reaching for a
sample, run the full pass instead.

**When an aggregation is worth repeating, write it down rather than retyping it.** Once you have
run the same one-liner for the third cluster, record it in `synapse/{repo}@{branch}/_profile.txt` — a
machine-only sibling of `_index.json`, never a node — as a fenced command plus one line on what
it revealed about *this* repo. **Read it, don't execute it:** it is a record of the aggregations
that earned their keep, so a later run applies the commands itself rather than shelling out to a
script fetched from a notes vault. Begin any re-run by reading it, and improve it rather than
re-deriving from scratch. Nothing like it ships, because which aggregations carry signal depends
on the codebase — a distributed one would encode the wrong ecosystem's conventions.

`.txt`, with markdown formatting inside, for a measured reason: Obsidian indexes `.md` files as
notes, so a `_profile.md` turns up in search, Quick Switcher and the graph, where it is pure noise
to a human reading notes. A non-`.md` extension is invisible to all of those and still perfectly
readable. Note the `_` prefix does *nothing* mechanically — it is only a hint to a human who sees
the file, matching `_index.json`. Record **negative results** here too ("this abbreviation has no
expansion anywhere in the repo"); a saved shell script cannot hold a search that came back empty,
which is the main reason this is prose rather than an executable.

## Choosing what to read

Once clusters exist, `synapse-rank.sh --sources lists/NN.txt` decides reading order — it does not
decide coverage, which stays exhaustive. Two pools, because the two halves of authoring want
different files:

```
synapse-rank.sh --sources lists/NN.txt --pool summary   # names: code, tests, DSL consumers
synapse-rank.sh --sources lists/NN.txt --pool crux      # implementation only, tests excluded
```

A summary is made of *names*, so test class names and the names of the code consuming a DSL file
both count as evidence at zero read cost. A crux is concentrated logic, so tests are excluded from
that half — density ranks them high for a structural reason (many small test methods, each a
definition, in a small file), and none of the recorded `crux_path` values on a real namespace is a
test.

**Read the top few, not the list.** The ranking exists so that reading 3 files out of 809 produces
the same summary as reading all of them, which is the measured result this whole approach rests on.

**Tree-sitter acceleration — handling `synapse-tags.sh`'s exit codes.** These are the *single-file*
form's codes. In `--paths` batch form an extension with no grammar produces one warning line on
stderr and the batch still succeeds, because a mixed repo nearly always has some language that
works and failing the whole batch for one would throw away every language that did.

**A missing grammar gets one line and nothing more.** No coverage report, no per-language
accounting: a file tree-sitter cannot parse is not source, and a non-source file has nothing to
contribute to a node's prose. Do not build a tally out of those warnings.

- **Exit 0:** use the printed tags directly as clustering signal for this file.
- **Exit 1:** this language is a known dead end (or tree-sitter/a C compiler isn't available at
  all) — fall back to a full read for this file, silently, no need to re-announce something
  already covered by the up-front C-compiler check.
- **Exit 2 ("needs discovery" — this extension has never been seen before):** run this discovery
  procedure once, then retry the script:
  1. Try the naming convention first: `https://github.com/tree-sitter/tree-sitter-{lang}` (covers
     most official grammars, e.g. OCaml) — a quick existence check, no reasoning needed if it
     just resolves.
  2. If that doesn't resolve, fall back to a web search for a community-maintained grammar for
     the language.
  3. Verify before trusting: whatever's found must actually ship a tags query — a repo existing
     isn't sufficient on its own, and plenty of grammars ship only `queries/highlights.scm`
     (`tree-sitter-bash` is the notable one: no tags query anywhere in its tree, so `sh` is a
     genuine `unsupported`). Check **both** the repo root and any sub-grammar subpath, in that
     order — multi-grammar repos split either way and neither is the rule:
     `tree-sitter-ocaml` puts a query under each of its three sub-grammars in `grammars/`, while
     `tree-sitter-typescript` keeps a single shared `queries/tags.scm` at the root serving both
     its `typescript/` and `tsx/` sub-grammars.
  4. Write the result back to `~/.claude/synapse-grammars.conf` (create it as `{}` first if it
     doesn't exist) — a positive entry (`{"repo": "...", "scope": "..."}`) if verified,
     `{"unsupported": true}` if nothing checks out. This is a permanent, cross-project cache
     keyed by extension — every future project skips rediscovery for this language entirely.

     **The key is the bare extension with no leading dot** — `"rs"`, never `".rs"`, because
     `synapse-tags.sh` derives it with `${BASENAME##*.}`. Getting this wrong fails *silently*
     and expensively: the lookup misses, the script keeps returning exit 2, and discovery
     re-runs for that language on every file in every project forever, caching nothing. So the
     file should end up shaped like this:

     ```json
     {
       "rs": { "repo": "https://github.com/tree-sitter/tree-sitter-rust", "scope": "source.rust" },
       "sh": { "unsupported": true }
     }
     ```
  5. Announce the outcome either way ("found/verified a grammar for `.rs`, cached" or "no usable
     tree-sitter grammar for `.rs`, falling back to full reads"), then retry
     `synapse-tags.sh {path}` now that the registry has an entry (falls back to a full read for
     this file per the Exit 1 case above if discovery came up empty).
