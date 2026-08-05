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
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo-name}/.

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
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo-name}/.
  Never the script's own location, and never the repo -- see below.

Reads   $SYNAPSE_WORK_DIR/manifest.tsv   title <TAB> include-ERE <TAB> exclude-ERE
Writes  $SYNAPSE_WORK_DIR/all.txt        enumerated tracked files (kept if present)
        $SYNAPSE_WORK_DIR/lists/NN.txt   one path list per manifest line
        $SYNAPSE_WORK_DIR/lists/NN.title the node title for that list
        $SYNAPSE_WORK_DIR/unassigned.txt files no node claimed

Prints enumerated/covered/unassigned counts, so a bad pattern shows up as a
number rather than a silent gap. $SYNAPSE_EXTRA_EXCLUDE_RE appends repo-specific
noise to the built-in exclusions.

Exit codes: 0 ok, 1 could not run, 2 usage error
```

## `synapse-build-project-index.sh`

Builds and uploads synapse/{repo}/Index.md -- the per-project node map, carrying
the `remote` field the SessionStart hook verifies before injecting a pointer.
Step 4 (last) of a scripted /synapse-init.

```
Usage: synapse-build-project-index.sh
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo-name}/.

Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (for titles and file counts)
       each node's `summary` frontmatter field, fetched from the vault

Run after the nodes exist: summaries are read back off the nodes, and a node that
is missing or has no `summary` is a hard error. Emits no repo-specific prose of
its own -- see docs/synapse-graph.md for why.

Note for agent callers: needs the sandbox disabled (localhost REST API).
```

## `synapse-push-nodes.sh`

Writes every node that has both a path list and an authored body. Step 2 of a
scripted /synapse-init.

```
Usage: synapse-push-nodes.sh [NN ...]      (default: every staged or authored node)
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo-name}/.

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

<node> may be given with or without the trailing `.md`.

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

## `synapse-tags.sh`

Prints `tree-sitter tags` output (definitions + name-based call references)
for a single file, cloning/registering that language's grammar on first use.
Deliberately dumb/mechanical -- no reasoning here. See sb-002's "Wiring"
section and its `synapse-grammars.conf` registry for the design.

```
Usage: synapse-tags.sh <file-path>
  Grammar cache dir: $SYNAPSE_GRAMMARS_DIR, default ~/.cache/synapse/grammars/.

Exit codes (every caller must fail soft on any non-zero and fall back to
reading the file directly -- this is never a hard dependency):
  0 - tags printed to stdout
  1 - not usable right now (missing tree-sitter/jq/C compiler, no
      extension, a registry entry marked `unsupported: true`, or a clone/
      registration failure) -- nothing else to try
  2 - extension has no registry entry at all -- the caller (a Claude
      procedure, e.g. /synapse-init) should run grammar discovery and
      retry, not treat this the same as a hard failure
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

Exit codes:
  0 - node written; prints "<file>\t<n> files\t<digest>"
  1 - could not run (missing dependency, no vault, remote mismatch, PUT failed)
  2 - usage error

Design rationale lives in docs/synapse-graph.md, not here.
```

