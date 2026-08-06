# Orienting in an unfamiliar repo

Shared reference. Read by `/synapse-init` (its orientation step) and by `/synapse-rebuild` when a
node lands in the *re-orient* class and its premises have to be re-derived rather than patched.

It lives here rather than inside either of them because it is technique, not procedure: how to find
where meaning lives in a tree you have never seen. Both callers need exactly the same technique, and
a copy in each is how the two start giving different advice.

The goal is not a
summary of every file; it is learning *where meaning lives in this particular tree* well enough
to cluster it and then write about it. Four questions, in order. They are language-agnostic; how
you answer each one is not, and deducing that on the spot is the work:

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
a few dozen lines before you read anything. Then read 2–4 specific files per node — the ones the
aggregates pointed at — for the `crux` quote and to confirm a hypothesis.

`synapse-tags.sh {path}` is available for question 4 in any language with a tree-sitter grammar
(see the exit codes below). **It takes one file per invocation, ~0.07s warm, so it cannot be run
over a whole cluster** — 15,000 files is ~18 minutes, and a 100k-file repo runs into hours. Which
means any use of it needs a sampling rule, and every fixed rule is biased in a way you must
choose deliberately: alphabetical is an accident, largest-file favours generated code and
god-classes, "files under an `api/` directory" bakes in a naming convention this repo may not
share, and most-referenced needs the full scan you were avoiding. **State the rule you picked and
why, or skip question 4** — a truncated symbol list looks authoritative and is worthless.

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

**Small repos are the easy case:** under a few thousand files you can afford a genuine per-file
pass — `synapse-tags.sh` first, falling back to reading the file whenever it exits non-zero for a
reason other than "needs discovery", or whenever the tags alone don't say what the file is for.
Do that when you can; the four questions above are what to do when you can't.

**Tree-sitter acceleration — handling `synapse-tags.sh`'s exit codes:**
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
