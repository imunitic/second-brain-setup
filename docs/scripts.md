# Synapse Tools: script reference

Generated from the header block of each script by `docs/generate-scripts-reference.sh`
— the same text the script prints for `--help`. Do not edit by hand; run the
generator, or `--check` it, which the test suite does.

Design rationale is not here: see [synapse-graph.md](synapse-graph.md) for the Graph these
scripts build and why they exist at all, and [synapse-vault.md](synapse-vault.md) for
the Vault that hosts it.

## `synapse-build-index.sh`

Builds and uploads synapse/{repo}/_index.json -- the machine-only reverse index
from every source path to the node filenames that claim it, plus _unassigned.
Step 3 of a scripted /synapse-init.

```
Usage: synapse-build-index.sh
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.

Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title, unassigned.txt
Writes synapse/{repo}/_index.json in the vault

Read by the PostToolUse staleness hook, so it must cover every enumerated file:
an edit to an unlisted path flags nothing stale. Tens of megabytes on a large
repo, hence jq rather than authoring it.

Note for agent callers: needs the sandbox disabled (localhost REST API).
```

## `synapse-build-lists.sh`

Enumerates a repo's tracked files and expands a node manifest into one path
list per node, then reports coverage. Step 1 of a scripted /synapse-init.

```
Usage: synapse-build-lists.sh [--reenumerate]
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
  Never the script's own location, and never the repo -- see below.

Reads   $SYNAPSE_WORK_DIR/manifest.tsv   title <TAB> include-ERE <TAB> exclude-ERE
Writes  $SYNAPSE_WORK_DIR/all.txt        enumerated tracked files (kept if present)
        $SYNAPSE_WORK_DIR/lists/NN.txt   one path list per manifest line
        $SYNAPSE_WORK_DIR/lists/NN.title the node title for that list
        $SYNAPSE_WORK_DIR/unassigned.txt files no node claimed

Prints enumerated/covered/unassigned counts, so a bad pattern shows up as a
number rather than a silent gap.

Two ways to drop more than the built-in exclusions, both OR'd together:
  ~/.claude/synapse-ignore-files.conf   one ERE per line, comments allowed
  $SYNAPSE_EXTRA_EXCLUDE_RE             a single ERE, for one-off invocations
Excluding a path removes it from the graph entirely -- no owning node, no
vault search hit, no staleness flag when it changes. Right for build output
and vendored code; wrong for anything whose edits still matter.

Files over $SYNAPSE_MAX_FILE_BYTES (default 1048576, 1 MB) are skipped and
reported, not dropped silently: no extension or name rule anticipates a
generated monster, and a silent skip makes `enumerated` disagree with the repo.

Exit codes: 0 ok, 1 could not run, 2 usage error
```

## `synapse-build-project-index.sh`

Builds and uploads synapse/{repo}/Index.md -- the per-project node map, carrying
the `remote` field the SessionStart hook verifies before injecting a pointer.
Step 4 (last) of a scripted /synapse-init.

```
Usage: synapse-build-project-index.sh
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.

Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (for titles and file counts)
       each node's `summary` frontmatter field, fetched from the vault

Run after the nodes exist: summaries are read back off the nodes, and a node that
is missing or has no `summary` is a hard error. Emits no repo-specific prose of
its own -- see docs/synapse-graph.md for why.

Note for agent callers: needs the sandbox disabled (localhost REST API).
```

## `synapse-gate.sh`

Flags candidate clusters that own no vocabulary of their own, before anyone
pays to author their prose. The one quality check /synapse-init never had:
coverage was already provable by regex expansion plus `comm`, but whether a
cluster corresponds to a *concept* was judgment, discovered only when someone
tried to write its summary and found there was nothing to say.

```
Usage: synapse-gate.sh --vocab <groupwords.tsv> [--all] [--top N]
  --vocab  cluster-keyed vocabulary: `cluster <TAB> word <TAB> count`, i.e.
           synapse-vocab.sh run with --lists. NOT the directory-keyed table --
           see "RUN IT ON CLUSTERS" below, which is the whole reason the
           threshold ever looked unstable.
  --all    print every cluster with its score, not only the flagged ones.
  --top    terms per cluster the rule looks at, default 8.

Prints `cluster <TAB> rare-count <TAB> flagged|ok <TAB> top terms`, one line
per flagged cluster -- so empty output means every cluster is differentiated,
matching the reporting convention of `synapse-query.sh stale`/`drift`/
`grounding`. `--all` adds the `ok` rows in the same shape rather than a
second one, so the same field positions parse either way.

THE RULE, and why it is this and not something more obvious:

  rare  := df <= max(2, N/20)      # N = number of clusters, df over clusters
  flag  := count of rare terms among the cluster's top TOP <= 1

Terms rank within a cluster by raw count. Ranking by tf-idf *sum* is what
fails: a sum follows frequency rather than rarity, and it put two known-bad
clusters near the TOP of the list. What separates a real concept from a
generic one is not how much distinctive vocabulary it has in total, it is
whether it has any at all -- so the rule counts near-unique terms rather than
weighing them.

Measured against the four known-undifferentiated clusters in syrius3@master
(46 nodes): tolerance 0 catches three with no false positives, tolerance 1
catches all four with no false positives, tolerance 2 catches four but flags
five good clusters as well. The `max(2, N/20)` form reduces to the constant
that worked at that corpus size and scales with cluster count instead of
needing recalibration per repo.

RUN IT ON CLUSTERS, NOT ON MODULE GROUPS. A few dozen candidate clusters, not
the several hundred directory groups that form the orientation evidence.
Document frequency across 500 groups means something entirely different from
document frequency across 46 clusters, and feeding the wrong table in is what
made the threshold look like it needed tuning.

KNOWN LIMIT, deliberately unfixed: the rule cannot distinguish "owns no
distinctive vocabulary" from "produced no vocabulary". Both present as zero
rare terms. In a single-language repo the ambiguity cannot arise. In a mixed
repo, a cluster whose code is in a language with no grammar is flagged as
undifferentiated when it should be left alone -- so treat a flag on such a
cluster as "look at it", which is all a flag ever means here. Whatever
eventually addresses mixed repos has to give this rule a parseable-fraction
signal to tell the two cases apart.

Exit codes:
  0 - ran. Flagged clusters, if any, are on stdout; a flag is advice to
      re-cluster or disperse, never a hard stop, so this is 0 either way.
  1 - could not run (unreadable or empty vocabulary file)
  2 - usage error
```

## `synapse-graph-clean.sh`

Removes Synapse namespaces whose branch was deleted upstream, and reports the
ones it cannot decide about. The only destructive tool in Synapse, which is why
it is a command you run rather than a hook that fires: these are notes in a
permanent vault, and the system should not delete them on inference.

```
Usage: synapse-graph-clean.sh [--dry-run]
       synapse-graph-clean.sh --help

  --dry-run  report what would be removed, delete nothing.

Operates on the repo containing $PWD, across every branch's namespace for it --
not just the branch checked out now.

What it does with each `synapse/{repo}@{branch}/` namespace:

  remove  the branch had an upstream and it is gone -- merged and deleted, the
          case this exists for. `git branch -vv` shows it as `[origin/x: gone]`.
  report  the branch is absent locally and no upstream can be confirmed. That
          covers a never-pushed branch deleted by hand, and a branch whose
          config went with it, which are indistinguishable after the fact.
          Reported for a human to remove, never deleted here.
  keep    anything else, including a branch that was never pushed and still
          exists -- work in progress, whose namespace is in active use.

A `git fetch --prune` runs first unless --dry-run: without it a deleted branch
still has a local remote-tracking ref, every namespace looks alive, and the
command silently does nothing.

In a repo with no remote there is no upstream to consult at all, so the test
falls back to whether the local branch still exists. Without that fallback the
first run in a remoteless repo would classify every namespace as deleted
upstream and wipe the lot.

Deletion is on-disk rather than over the REST API, which would need one call
per note. The vault's own git history (see synapse-db-sync.sh) is the undo.

Exit codes:
  0 - ran (removed something, or found nothing to remove)
  1 - could not run (no vault, not in a git repo, missing dependency)
  2 - usage error
```

## `synapse-identity.sh`

Sourced by every component that has to name a Synapse namespace. One copy on
purpose: synapse-staleness.sh already carried a comment warning that a
divergent resolution chain makes one component refuse where another proceeds,
and that warning applied to five inline copies of the same logic. This is that
chain, once.
A namespace is keyed by repo AND branch -- `synapse/{repo}@{branch}/` -- so the
graph describes one tree rather than every branch at once. Worktrees need no
handling of their own: git refuses to check out one branch in two worktrees of
a repository (the main checkout included), so a branch already names at most
one checkout. That is why there is no `.git`-file parsing here, no `gitdir:` or
`commondir` walking, and no worktree-versus-submodule discrimination -- the
whole question reduces to which branch is checked out.
Usage (sourced, never executed):
  . "$HOME/.claude/bin/synapse-identity.sh"
  REMOTE="$(synapse_remote "$REPO_ROOT")"           # identity, unchanged chain
  NS="$(synapse_namespace "$REPO_ROOT")" || ...     # "{repo}@{branch}"
Deliberately does NOT `set -euo pipefail`: a sourced file that sets shell
options silently rewrites its caller's error handling. Every git call below is
guarded instead, so these stay safe under a caller that does set them -- which
all the hooks do.

```
```

## `synapse-push-nodes.sh`

Writes every node that has both a path list and an authored body. Step 2 of a
scripted /synapse-init.

```
Usage: synapse-push-nodes.sh [NN ...]      (default: every staged or authored node)
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.

Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (from synapse-build-lists.sh)
       $SYNAPSE_WORK_DIR/b-NN.md                   (authored per node, see below)
Calls  synapse-write-node.sh once per node.

Each b-NN.md carries its own one-line summary in frontmatter, so everything
authored about a node lives in one file:

    ---
    summary: One line differentiating this node from its siblings.
    ---

    ## Summary
    ...

The frontmatter is stripped before the rest is passed on as the node body, and the
summary becomes the node's `summary` field. A node without one is an error rather
than a default, because the index bullet has nothing to say without it.

Note for agent callers: needs the sandbox disabled (localhost REST API).
```

## `synapse-query.sh`

Read-only queries against a repo's Synapse graph. Reads the expensive parts
internally and prints only what was asked for.

```
Usage: synapse-query.sh <subcommand> [args]   (operates on the repo containing $PWD)

  body    <node>                     fenced prose only, no frontmatter
  sources <node>                     every path the node covers
  sources <node> --count             just the number
  sources <node> --modules           module<TAB>count, LC_ALL=C sorted
  sources <node> --filter <pattern>  matching paths only (substring)
  field   <node> <key>               one top-level frontmatter scalar
  stale                              nodes whose files no longer match, with a reason
  drift                              what changed since each node's recorded commit
  grounding                          nodes whose recorded evidence no longer matches
  grounding <node> --list            that node's groundings, as path<TAB>lines
  links   <node>                     outbound relations, as relation<TAB>target
  links   <node> --inbound           what points here, as relation<TAB>source
  links   <node> --closure           every node reachable outbound, depth<TAB>node
  links   --check                    link targets that resolve to no node
  symbol  <name> <node>              exact-name def/ref hits across the node's
                                     sources, as path<TAB>tag-line (see below)

<node> may be given with or without the trailing `.md`.

`symbol` is a name-based, not type-resolved, lookup backed by a per-project
tags cache ($SYNAPSE_WORK_DIR/_tags_cache.json, default
~/.claude/synapse-work/{repo}@{branch}/) kept current as a byproduct of node
build/regeneration, with any file the cache is missing tagged lazily on the
spot. Set SYNAPSE_DISABLE_SYMBOL_CACHE (any value) to disable entirely --
see docs/synapse-graph.md's "Exact-symbol lookup" section for the full design.

That cache sits beside the work dir rather than in the vault because it is
derived, disposable and large: at syrius3 scale ~942 MB against _index.json's
26 MB, and the vault is version-controlled, so every rebuild would commit a
fresh copy of it into the vault's history. Deleting it costs one re-tag.

`stale` re-hashes what a node claims; `drift` diffs its recorded `commit` against
HEAD, so only `drift` sees added, deleted and renamed paths. Neither pulls.
When to use which, and why any of this is a script: docs/synapse-graph.md.

Exit codes:
  0 - ran successfully. Empty output means clean for every reporting subcommand:
      `stale`, `drift`, `grounding` and `links --check`. `drift` prints context
      (commits behind, commits since baseline) only alongside a finding, so its
      silence means the graph matches the worktree rather than that it gave up.
  1 - could not run (missing dependency, no vault, no namespace, remote
      mismatch, unknown node). Treat as "no information", never as "clean".
  2 - usage error (unknown subcommand, bad flag, unsupported field)
```

## `synapse-tags-cache.sh`

Keeps a project's synapse-tags.sh output cache current for a given set of
files, re-tagging only what changed and doing so in parallel when several
files need it. Shared by node build/regeneration (piggybacked on the same
per-file hash comparison it already performs) and synapse-query.sh's
`symbol` subcommand (lazy backfill on a cache miss). See docs/synapse-graph.md's
"Exact-symbol lookup" section for the full design and the measured cost of
a cold, fully-uncached run.

```
Usage: synapse-tags-cache.sh --repo-root <path> --cache <_tags_cache.json path> --paths <file>
  --paths  file of repo-relative path<TAB>current-git-hash lines, one per
           file the caller wants current in the cache (a node's `sources`,
           typically -- the caller already has both path and hash).

  Parallelism: xargs -P, capped at nproc/sysctl -n hw.ncpu (falls back to 4),
  fed NUL-terminated records so paths containing spaces survive intact.
  Every worker tags one file and writes its own result to a private temp
  file; a single sequential step afterward merges those into the cache in
  one pass. No worker ever writes the shared cache file directly.

  A file synapse-tags.sh can't check (no grammar, no tree-sitter, no C
  compiler -- its own exit 1/2) is still recorded, as `unsupported: true`
  with empty tags, so it isn't silently re-attempted on every call. That is
  a distinct outcome from "checked, symbol not present" -- callers must
  report it as such, never as a plain non-match.

Exit codes:
  0 - cache is current for every requested path (already-current paths need
      no work; this is also the outcome when nothing needed tagging at all)
  1 - usage error, missing dependency, or the cache could not be read/written
```

## `synapse-tags.sh`

Prints `tree-sitter tags` output (definitions + name-based call references),
cloning/registering each language's grammar on first use. Deliberately
dumb/mechanical -- no reasoning here. See docs/synapse-graph.md's "Optional
tree-sitter acceleration" section and `synapse-grammars.conf`'s own header.

```
Usage: synapse-tags.sh <file-path>
       synapse-tags.sh --paths <file-list>
  Grammar cache dir: $SYNAPSE_GRAMMARS_DIR, default ~/.cache/synapse/grammars/.

`--paths` tags every listed file in ONE tree-sitter invocation. That is not a
convenience: CLI startup and grammar load dominate the per-file cost, and 200
Java files measured 0.076s batched against 2.543s as 200 invocations across 12
workers -- 33x, single-threaded against parallel. At 20,000 files a single
invocation runs ~17.5s, so per-file work is real; startup simply swamped it at
any size below a few thousand. Anything walking a whole repository should use
this form.

Output is attributable in both forms: an unindented line is a path, and the
tab-indented lines under it are that path's tags.

A mixed-extension list is fine and is why batch mode passes no `--scope`:
tree-sitter infers the language per file from its extension, whereas forcing a
scope makes it parse every file as that language (verified -- a `.gradle` file
in a Java-scoped batch is parsed as Java). Single-file mode keeps `--scope`,
which is exact and preserves its existing behaviour.

Extensions with no usable grammar are reported once each on stderr and skipped;
tree-sitter's own warning is eight lines per FILE, which is unreadable at repo
scale. One line per extension is all a caller can act on.

Exit codes (every caller must fail soft on any non-zero and fall back to
reading the file directly -- this is never a hard dependency):
  0 - tags printed to stdout. In `--paths` mode this is the outcome whenever
      the batch ran, even if some extensions had no grammar: a mixed repo
      nearly always has some, and failing the batch for them would throw away
      every language that did work.
  1 - not usable right now (missing tree-sitter/jq/C compiler, no
      extension, a registry entry marked `unsupported: true`, or a clone/
      registration failure) -- nothing else to try
  2 - extension has no registry entry at all -- the caller (a Claude
      procedure, e.g. /synapse-init) should run grammar discovery and
      retry, not treat this the same as a hard failure.
      Single-file mode only: a batch spanning many extensions has no single
      answer, so it warns per extension and returns 0.
```

## `synapse-tokenizer.sh`

Turns a raw prompt into a handful of distinctive terms for a `regexp` OR-pattern,
entirely mechanically -- no LLM call, cheap enough to run on every turn. Built for
the per-prompt context injection hook; see docs/synapse-graph.md's "What every
prompt is told" section for the full mechanism this feeds.

```
Usage: synapse-tokenizer.sh <prompt>
  Character class: $SYNAPSE_TOKENIZER_EXTRA_CHARS, default empty -- appended onto
    the base A-Za-z_ class. A Lisp/Clojure/Scheme repo (hyphenated identifiers
    like `make-instance`) sets this to `-`; appending keeps it at the end of the
    bracket expression, which is exactly where a literal `-` needs no escaping.
  Stopwords file: ~/.claude/synapse-prompt-stopwords.conf (installed by setup.sh
    from synapse-prompt-stopwords.conf.template; English by default, extensible
    per that file's own header).

Prints surviving terms, one per line, first-letter bracket-cased (e.g.
`Cached_backend` -> `[Cc]ached_backend`) -- join with `|` for a regexp pattern.
Exit codes: 0 always; empty output means nothing survived (a purely
conversational prompt), which the caller should treat as "nothing to inject."
```

## `synapse-vocab.sh`

Reduces a whole repository to its symbol vocabulary, grouped by directory:
`group <TAB> word <TAB> count`. Evidence for the clustering step of
/synapse-init, so that deciding what a subsystem is about costs symbol names
rather than source lines. See docs/synapse-graph.md's "Orientation from
vocabulary" section.

```
Usage: synapse-vocab.sh [--repo <path>] [--depth N] [--chunk N] [--out <dir>]
                        [--lists <dir>]
  --repo   default: the git toplevel containing $PWD.
  --depth  directory levels that make a group, default 2 (`src/main` from
           `src/main/java/Foo.java`). A path shallower than that groups by
           whatever prefix it has; a repo-root file groups as `(repo root)`.
  --chunk  files per tree-sitter invocation, default: one chunk per core,
           floor 500. Only a parallelism knob -- see below.
  --out    default: $SYNAPSE_WORK_DIR, i.e. ~/.claude/synapse-work/{repo}@{branch}/.
  --lists  key by CLUSTER instead of by directory: a synapse-build-lists.sh
           lists/ dir, where each NN.txt is a node's paths and NN.title its
           name. Files no list claims are skipped. --depth is then unused.

Writes  <out>/groupwords.tsv   group <TAB> word <TAB> count, group then count desc
        <out>/counts.tsv       group <TAB> file count, count desc

TWO GROUPINGS, ONE SCRIPT, AND WHY BOTH ARE NEEDED. Directory grouping is the
orientation evidence -- it exists before anyone has decided what the nodes
are, which is the whole point of it. Cluster grouping is what the quality gate
scores, and a cluster is not generally a union of directories, so it cannot be
derived from the directory-keyed table after the fact. The second run costs
another tagging pass (~51s on syrius3) against a build that was measured in
hours, so exactness was the cheaper side of that trade.

Prints groups / files / code files / pairs on stderr, so a repo that yielded
no vocabulary is a number rather than an empty file nobody looked at.

WHY THIS IS AFFORDABLE. Tagging goes through `synapse-tags.sh --paths`, one
invocation per chunk, because CLI startup and grammar load are nearly all of
the per-file cost: 200 files measured 0.076s batched against 2.543s as 200
invocations across 12 workers. The whole of syrius3 (125,351 files, 98k of
them code) takes ~51s. Chunking exists only to use more than one core; it is
not what makes this cheap.

RAW TAGS ARE NEVER STORED. Each worker pipes `synapse-tags.sh` straight into
the word reduction and keeps only `group <TAB> word`. The tags themselves are
~942 MB on syrius3 against 6.9 MB of vocabulary, so writing them out first
would cost more disk than the entire graph.

EVERY TRANSFORM IS awk, NOT sed. `sed` works on whole lines, so a character
class meant for the symbol field also mangles the group key and the tab
between them -- and BSD `sed` reads `\t` inside a bracket expression as a
literal `t`, which silently destroys the field separator rather than erroring.
Everything runs under LC_ALL=C for the same class of reason: macOS `awk`
aborts mid-stream on Latin-1 bytes, which real repos contain.

Word splitting matches the identifier conventions, not English: `getUserName`
gives get/user/name, `user_name` gives user/name, and a run of capitals stays
with what follows it (`HTTPServer` is one word). Words shorter than 4
characters, pure digits, and anything in ~/.claude/synapse-prompt-stopwords.conf
are dropped -- the same list the prompt tokenizer uses, deliberately, because
two stopword lists that disagree is how two mechanisms start giving different
answers.

Exit codes:
  0 - ran. An EMPTY groupwords.tsv is a legitimate outcome (no file had a
      usable grammar) and the caller must test for it: that is the signal to
      fall back to `synapse-orientation`, not an error to report.
  1 - could not run (not a git repo, no synapse-tags.sh, no work dir)
  2 - usage error
```

## `synapse-write-node.sh`

Writes one Synapse node into the vault: hashes every source path, computes
sources_digest, records the baseline `commit`, builds the aggregated `## Sources`
mirror, and PUTs the note via the Obsidian Local REST API.

```
Usage: synapse-write-node.sh --title <t> --summary <s> --paths <file> --body <file>
       synapse-write-node.sh --help

  --title    node title. Used verbatim as the H1, and sanitized for the filename.
  --summary  one line for the index bullet, stored as the `summary` frontmatter
             field. Written for the index, not as the node's opening sentence.
  --paths    file of repo-relative paths, one per line: every file the node covers.
  --body     file holding the authored prose (## Summary / ## Crux / ## Links).
             `## Sources` and the generated fences are added by this script.

The body must not contain crux code. It points instead:

  <!-- crux: crates/matcher/src/lib.rs 412-419 -->     slice these lines
  <!-- crux: none -->                                  no single span carries it

This script cuts the text out of the file, fences it with a language guessed
from the extension, appends a `path:start-end` provenance line, and records
`crux_path`/`crux_lines` in frontmatter. The path must be one the node claims
and the range must be under 20 lines, or the write is refused.

The body may also carry any number of grounding pointers — the evidence a
summary rests on, typically a doc comment or a test:

  <!-- grounded_in: src/main/java/Foo.java 10-14 -->

These are recorded in the `grounded_in` frontmatter list as path + lines +
sha256 of the sliced text, then stripped from the body: provenance, not
display. Same path and range checks as the crux, with a 40-line cap.

Writes to the vault over the Obsidian Local REST API on 127.0.0.1. Agent callers
need the network sandbox disabled, or curl fails with exit 7 and no message.

As a byproduct it refreshes $SYNAPSE_WORK_DIR/_tags_cache.json (default
~/.claude/synapse-work/{repo}@{branch}/) for the node's sources, so
`synapse-query.sh symbol` is a cache read. That file is derived and
disposable, which is why it lives beside the work dir rather than in the
version-controlled vault. Never fatal; SYNAPSE_DISABLE_SYMBOL_CACHE skips it.

Exit codes:
  0 - node written; prints "<file>\t<n> files\t<digest>"
  1 - could not run (missing dependency, no vault, remote mismatch, PUT failed)
  2 - usage error

Design rationale lives in docs/synapse-graph.md, not here.
```

