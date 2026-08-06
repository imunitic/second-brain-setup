# Synapse Init: Build or Refresh a Repo's Code-Graph Namespace

Builds a repo's Synapse Graph namespace in Synapse Vault — a small set of LLM-authored node
notes (summary + crux + typed links per subsystem/concept) plus the two derived projections that
keep it cheap to consult and keep stale (`_index.json`, `synapse/{repo}@{branch}/Index.md`).

This is the **only** way a project gets a Synapse namespace in the first place — nothing else in
this system creates one unprompted, matching the "zero cost for projects that never opt in"
constraint. Run it once per repo to bootstrap; running it again later is a lighter operation (see
"Already initialized" below), not a full rebuild.

## Usage

```
/synapse-init
```

No arguments — always operates on the repo containing the current working directory.

## Prerequisites

- Requires the `obsidian` MCP server (`mcp__obsidian__*` tools). If unreachable, say so and stop.
- Must be run from inside a git repository. Synapse assumes git throughout (source hashing uses
  `git hash-object`, file enumeration uses `git ls-files`) — if `git rev-parse --show-toplevel`
  fails, stop and say this only works inside a git repo.
- **Tree-sitter acceleration (optional, never blocking):** check once, up front, whether a C
  compiler is available (`command -v cc`, falling back to `gcc`/`clang`). Missing → print one clear,
  friendly note ("no C compiler found; Synapse will use its full-read behavior for this project, no
  tree-sitter acceleration") and proceed with every step below exactly as if this section didn't
  exist — never let a raw `cc`/build error surface later from inside a grammar build. This check
  gates whether "Tree-sitter acceleration" below is attempted at all for this run; nothing else in
  `/synapse-init` depends on its result.

## Resolving repo context

Every step below needs the same three facts, resolved once up front:

1. **Repo root:** `git rev-parse --show-toplevel`.
2. **Namespace key:** `{repo}@{branch}`, resolved by `synapse_namespace` in
   `~/.claude/bin/synapse-identity.sh` — never derived by hand here, since every component reads it
   from that one place and a second derivation is how they start disagreeing. The repo half comes
   from the *remote's* basename, not the directory: a linked worktree's directory name differs from
   its parent's, and that difference is exactly what must not matter. The branch half is
   `git symbolic-ref --short HEAD`, with `/` and other filename-hostile characters translated.

   A namespace describes **one branch**. That is the point: it keeps `commit`, the per-file hashes
   and `stale` describing a single tree, and it means a branch switch leaves the old graph intact
   rather than invalidating it wholesale.

   **On a detached HEAD, stop.** There is no branch, so there is no key — `synapse_namespace` exits
   1 and says so. Do not invent one, and do not fall back to the directory name: every detached
   checkout everywhere would collide on the same value. Tell the user to check out a branch first.

   Distinct from the short task-prefix scheme (`project-name=prefix`) used by
   `/synapse-note`/`/synapse-design-note` — unrelated conventions that happen to both involve the
   word "project."
3. **Remote:** `git remote get-url origin` (or any configured remote if `origin` doesn't exist —
   pick the first one `git remote` lists). If the repo has no remote at all, fall back to the
   repo root's absolute path. This is the verification field written into the per-project
   `Index.md` and checked by the `SessionStart` hook before it ever injects a pointer.

## Already initialized?

Check whether `synapse/{repo}@{branch}/Index.md` exists (`mcp__obsidian__vault_list` on
`synapse/{repo}@{branch}/`, or a direct `vault_read` attempt).

- **Doesn't exist** → this is a first-time build. Go to "First-time build" below.
- **Exists, `remote` frontmatter matches** the resolved remote/path → this namespace already
  belongs to this repo. Nothing here needs a full rebuild (regeneration is handled lazily at read
  time — see the design note's Generation & Regeneration section); the only thing `/synapse-init`
  still does for an already-initialized project is the manual "process it now" sweep of
  `_unassigned` — go to "Re-running on an initialized project" below.
- **Exists, `remote` mismatches** → `synapse/{repo}@{branch}/` belongs to a *different* repo that
  happens to share this key. Do not touch it. Stop and tell the user plainly: "A Synapse
  namespace already exists at `synapse/{repo}@{branch}/` for a different remote/path
  (`{existing remote}`) — this repo's remote is `{resolved remote}`. Refusing to overwrite; rename
  one of the two repos, or pick a different resolution, before initializing here." This is the
  same detect-and-flag asymmetry the `SessionStart` hook uses — contaminating one project's graph
  with another's is worse than a blocked command.

## First-time build

**Two kinds of work, and the seam between them.** Everything here is either *mechanics* — fixed,
language-agnostic, and already implemented as a tested script — or *interpretation*, which is
yours and cannot be scripted because what counts as signal differs per codebase.

- **Mechanics (do not reimplement inline):** `synapse-vocab.sh` (repo → per-group symbol
  vocabulary), `synapse-build-lists.sh` (enumerate + expand a manifest + prove coverage),
  `synapse-gate.sh` (flag clusters that own no vocabulary), `synapse-rank.sh` (which files are
  worth reading), `synapse-write-node.sh` (hash, digest, `## Sources` mirror, PUT),
  `synapse-push-nodes.sh`, `synapse-build-index.sh`, `synapse-build-project-index.sh`.

**The work directory** defaults to `~/.claude/synapse-work/{repo}@{branch}/`, created on demand, and
holds `manifest.tsv`, `all.txt`, `lists/`, the authored `b-NN.md` bodies and the coverage files. Override with `$SYNAPSE_WORK_DIR` if you need to. Two things never to do: point it
at the repo (these scripts run from inside the repo, so its working files would land in the user's
checkout) or at the vault (Obsidian would index a file list that runs to six figures of lines).
It is deliberately persistent rather than a temp dir, so a later run finds the previous manifest
instead of re-deriving the clustering.
- **Interpretation (only you can do this):** deciding what the nodes *are*, and writing their prose.

The seam is **`manifest.tsv`** — `title <TAB> include-ERE <TAB> exclude-ERE`, one line per node.
Your judgment goes in as a few dozen regexes; everything downstream of that file is mechanical and
verifiable. Note the practical consequence: a node's `sources` is exhaustive by construction
because a script expands it, so the "never a context read" rule holds in **both** directions — a
125k-file namespace is ~10 MB of frontmatter plus a ~29 MB `_index.json`, which you can no more
emit into tool calls than read into a window. Never hand-author those.

1. **Enumerate files** — mechanics, run `synapse-build-lists.sh` (it does this step and step 4's
   expansion together, and reports coverage). It enumerates `git ls-files` from the repo root —
   tracked files only, which gets
   `.gitignore` exclusion for free and matches what's actually worth summarizing (build output,
   dependencies, etc. are never tracked), and it drops binary/generated files — images, compiled
   objects, packages, archives, media, model weights, lockfiles, minified bundles and source maps.
   Those lists are grouped by *what a file is* rather than by ecosystem, so they are not JVM- or
   web-specific; add repo-specific noise through `$SYNAPSE_EXTRA_EXCLUDE_RE` (it appends to the
   defaults) rather than editing the script.

   **Submodule gitlinks are skipped for you**, but know why, because it explains a failure you will
   otherwise meet: `git ls-files` reports a submodule as a single entry, but it is a directory on
   disk — `git hash-object` fails on it and takes the whole batch down with it. Its contents belong
   to another repo, which can have its own namespace, so it never belongs in `sources`. The
   detection is a plain "is this a regular file" test rather than parsing `.gitmodules`, and a hash
   is never synthesised from `git ls-files -s`: that would leave the writer and
   `synapse-query.sh stale` using different commands for one entry, which is exactly the kind of
   asymmetry that produces a permanent false positive.
2. **Read hint files, if present:** `CLAUDE.md` and `README.md` at the repo root. These bias the
   clustering pass in step 4 — they are never treated as authoritative structure, and the pass can
   and should diverge from them if the files themselves disagree. No other project-specific doc
   convention (e.g. a `docs/design/` folder) gets this treatment — see the design note's
   Alternatives for why that was rejected.
3. **Orientation pass — the evidence is mechanical, the reading of it is yours.** Run
   `synapse-vocab.sh`. It writes `groupwords.tsv` (`group ⇥ word ⇥ count`) and `counts.tsv`
   (`group ⇥ file count`) into the work directory, covering every file that has a grammar — the
   whole of syrius3, 125,351 files, in ~51 seconds. Read those two tables instead of exploring the
   tree.

   What is *not* mechanical, and is the actual work: deciding which words are **distinctive**
   rather than merely frequent. A word in every group is background; a word in two is a concept.

   An empty `groupwords.tsv` means no file here had a usable grammar. That is a supported state, not
   an error — fall back to the four questions in the skill below.

   **Load the `synapse-orientation` skill** for how to read the vocabulary, the four questions that
   cover a tree with no grammar, and the grammar-discovery procedure. It is shared with
   `/synapse-rebuild`'s re-orient class, which needs the same technique.
4. **Cluster into nodes — write `manifest.tsv`, the seam.** Group what you learned into a few dozen
   readable nodes, not one per file — same density Graft aims for. A node is a subsystem or concept,
   not a file; a file may legitimately belong to more than one node's `sources` when it's genuinely
   load-bearing for two concepts (many-to-many is intentional, not an oversight). Use the
   `CLAUDE.md`/`README.md` content read in step 2 as a bias on grouping and naming, never as a
   boundary the files themselves don't support.

   Express each cluster as one line in `$SYNAPSE_WORK_DIR/manifest.tsv`:

   ```
   title <TAB> include-ERE <TAB> exclude-ERE
   ```

   Then run `synapse-build-lists.sh` and **read the coverage report it prints.** `covered` +
   `unassigned` must account for `enumerated`; anything unclaimed lands in `unassigned.txt` and
   flows into `_index.json`'s `_unassigned`. Iterate the manifest until the split is deliberate
   rather than accidental — a regex slip like `config$` (which matches only a file literally named
   `config`, not the directory) shows up here as a count, which is the entire reason this step is a
   file plus a script instead of a judgement you make silently.

   Keep the manifest: it is the reviewable record of a judgment call, and re-running or extending
   the namespace later should start from it rather than re-deriving the clustering. Copying it to
   `synapse/{repo}@{branch}/_manifest.tsv` alongside `_index.json` is worth doing for any repo you
   expect to revisit.
5. **Gate the clusters — before paying to author any prose.** Coverage was already provable in step
   4; cluster *quality* was not, and a bad cluster used to be discovered only when someone tried to
   write its summary and found there was nothing to say.

   ```
   synapse-vocab.sh --lists "$SYNAPSE_WORK_DIR/lists"   # re-key the vocabulary by CLUSTER
   synapse-gate.sh  --vocab "$SYNAPSE_WORK_DIR/groupwords.tsv"
   ```

   The second run of `synapse-vocab.sh` is not redundant. A cluster is generally *not* a union of
   directories, so cluster vocabulary cannot be derived from the directory-keyed table of step 3;
   the extra tagging pass (~51s on a very large repo) buys exactness. Note it overwrites
   `groupwords.tsv`/`counts.tsv` — pass `--out` if you want to keep the directory-keyed pair.

   Empty output means every cluster is differentiated; go on to step 6. Each line printed is a
   cluster whose top eight terms are nearly all corpus-common, i.e. it owns no vocabulary of its
   own. **Re-cluster or disperse those before authoring** — merge into a neighbour, split along a
   distinction the vocabulary actually shows, or drop the line and let its files land in a better
   node. Then re-run `synapse-build-lists.sh` and the gate.

   A flag is advice, never a hard stop, and there is one case where the right answer is to override
   it: a cluster whose code is in a language with **no tree-sitter grammar** produces no vocabulary,
   which is indistinguishable from owning none. If that is why it was flagged, leave it alone and say
   so.
6. **Write each node.** Author the prose only — put each node's content in
   `$SYNAPSE_WORK_DIR/b-NN.md` (matching its `lists/NN.txt`), then run `synapse-push-nodes.sh`,
   which calls `synapse-write-node.sh` per node.

   **Do not choose which files to read by judgment.** Ask:

   ```
   synapse-rank.sh --sources "$SYNAPSE_WORK_DIR/lists/NN.txt" --pool summary
   synapse-rank.sh --sources "$SYNAPSE_WORK_DIR/lists/NN.txt" --pool crux
   ```

   Read the top few of each, not the list — on a real node a summary authored from 3 files out of
   809 matched the hand-written one. The two pools differ deliberately: a summary is made of *names*
   so it keeps test classes and DSL consumers, while a crux is concentrated logic so it excludes
   tests. Both leave `sources` exhaustive; this is reading order only.

   **Load the `synapse-node-format` skill before writing the first one.** It is the single
   description of the node contract — summary, the crux *pointer*, `## Links`, `grounded_in`, what
   the writer adds and what it refuses — shared with the `synapse-node` skill and `/synapse-rebuild`,
   which write the same artifact. Do not re-derive the format from an existing node: a node you are
   reading may predate a change to it.
7. **Write `_index.json`** — mechanics, run `synapse-build-index.sh`. It emits
   `synapse/{repo}@{branch}/_index.json`, mapping every source path used
   above to the list of node **filenames, including the `.md` extension** (matching the design
   note's schema exactly, since the `PostToolUse` hook and the read-time procedure both use this
   value directly as a vault path with no extension-handling of their own) that claim it, plus an
   `_unassigned` array for any enumerated file that didn't end up in any node's `sources` (e.g. a
   file judged not worth its own concept but not discardable either — leave it here rather than
   forcing a bad fit). This file is derived and machine-only — nothing edits it directly except
   this command and the `PostToolUse` staleness hook.

   ```json
   {
     "eon_ecs/world.ml": ["World — entity_component_resource core.md"],
     "eon_ecs/world.mli": ["World — entity_component_resource core.md"],
     "_unassigned": []
   }
   ```

8. **Write `synapse/{repo}@{branch}/Index.md`** — mechanics, run `synapse-build-project-index.sh`. It
   takes no prose from you at all: each bullet's headline is read back from that node's `summary`
   frontmatter field, and the script computes the exact file count, the sanitized wikilink filename
   and the `remote` field. Bullets come out sorted by title. Run it only after the nodes exist — it
   fails loudly on a node that is missing or has no `summary`, both of which mean the namespace is
   incomplete.

   The result is the per-project map, and nothing more: **the index carries no repo-specific prose.**
   That is not a limitation to work around. A convention worth explaining — a module-name/package-name
   divergence, a layering rule, an overlay mechanism found during the orientation pass — is a
   *concept*, and concepts are **nodes**. Written as a node it gets `sources` (so it is reachable by
   searching any file that evidences it), staleness tracking when that evidence changes, and typed
   links from the domains it affects. Written as index chrome it gets none of those. If the
   orientation pass produced a finding a newcomer needs in the first five minutes, give it a node and
   let that node's `summary` carry the headline.

   **Then verify, before reporting success.** Three checks, all cheap:
   - `synapse-query.sh stale` must print nothing. (40s for a 125k-file namespace.)
   - Every `[[wikilink]]` in the namespace must resolve to a file that exists — extract them all and
     test `-f "$link.md"`. Nothing else catches a broken link, since Obsidian treats it as a link to
     a note not yet created.
   - Every node file must appear in `Index.md`. An unlisted node exists but is invisible to a reader.

   ```yaml
   ---
   title: "{repo}@{branch} — Synapse index"
   node_type: synapse-index
   project: {repo}
   branch: {branch}
   remote: "{resolved remote or path}"
   built_at: "<now>"
   ---

   # {repo}@{branch} — Synapse index

   - [[World — entity/component/resource core]] — {one-line summary} (built {built_at})
   - ...
   ```

## Re-running on an initialized project

This is the manual fallback for the `_unassigned` sweep that normally rides along on any lazy
regeneration (see the design note's Node Granularity & Grouping) — for a project that's gone fully
dormant and has no other regeneration event to piggyback on. It does **not** re-cluster or rebuild
existing nodes.

1. Read `synapse/{repo}@{branch}/_index.json`'s `_unassigned` array. Empty → report "Nothing
   unassigned, nothing to do" and stop.
2. Read `synapse/{repo}@{branch}/Index.md` for the current node list (titles + summaries).
3. Tag them **in one call, not one per file**: write the unassigned paths to a list and run
   `~/.claude/bin/synapse-tags.sh --paths {list}`. Output is attributable — an unindented line is a
   path, the tab-indented lines under it are that path's tags — so one invocation classifies the
   whole sweep. A per-file loop here costs ~33× more for the same answer, and `_unassigned` on a
   large repo is not a short list. Fall back to a full read only for genuinely ambiguous cases.
   Classify against the existing node list.
   - **Fits an existing node** → append it (path + fresh `git hash-object`) to that node's
     `sources` in frontmatter, and set that node's `stale: true` (it now covers a file it hasn't
     summarized yet — its own next read regenerates it, this step does not regenerate it
     immediately). Remove the path from `_unassigned` and add it under that node's key in
     `_index.json`.
   - **Fits nothing** → leave it in `_unassigned`.
   - Announce each outcome as it happens (which file, which node or "still unassigned").
4. Do not touch `built_at` on `Index.md` itself for this pass — the sweep doesn't rebuild the
   index projection, only the affected nodes' own frontmatter and `_index.json`.

## Confirm

- **First-time build:** report the namespace path, node count, and a reminder that the
  `SessionStart` hook will now pick this project up automatically.
- **Re-run:** report how many unassigned files were resolved, how many remain, and to which nodes
  anything was attached.
- **Namespace collision:** the refusal message from "Already initialized" above — nothing is
  written.

## Integration

- Nodes and projections written here are read by Claude directly at Synapse read time (Tier 2
  staleness check + regeneration — a procedure, not a hook, documented alongside this command) and
  flagged stale by the `PostToolUse` hook on every subsequent edit to a source file.
- The `SessionStart` hook's pointer injection depends on this command having run at least once —
  it does a plain existence check on `synapse/{repo}@{branch}/Index.md` and does nothing if this was
  never run.
