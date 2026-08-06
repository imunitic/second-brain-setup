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

- **Mechanics (do not reimplement inline):** `synapse-build-lists.sh` (enumerate + expand a
  manifest + prove coverage), `synapse-write-node.sh` (hash, digest, `## Sources` mirror, PUT),
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
3. **Orientation pass — interpretation, and the step nothing can do for you.** The goal is not a
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
5. **Write each node.** Author the prose only — put each node's content in
   `$SYNAPSE_WORK_DIR/b-NN.md` (matching its `lists/NN.txt`), then run `synapse-push-nodes.sh`,
   which calls `synapse-write-node.sh` per node. The contract below is what that writer implements
   and what `synapse-query.sh stale` verifies; it is specified here because the two must agree
   exactly, not because you should hand-build the file. A node lands at
   `synapse/{repo}@{branch}/{Node Title}.md`:

   Each `b-NN.md` opens with its own one-line summary in frontmatter, so everything authored about a
   node is in one file:

   ```markdown
   ---
   summary: One line differentiating this node from its siblings.
   ---

   ## Summary
   ...
   ```

   The driver strips that frontmatter and the line becomes the node's `summary` field, which step 7
   reads back to build the index bullet. Write it *for the index* — it has to distinguish this node
   from dozens of siblings, which is a different job from the node's opening sentence, whose job is
   to orient someone already inside. A node without one is an error, not a default.

   - **Filename/title:** short, senior-engineer-style description of the concept (e.g. "World —
     entity/component/resource core"). Filesystem-illegal characters (`/ : * ? " < > |`) are
     sanitized — but **reword the title instead of relying on that**, because Obsidian resolves a
     wikilink by *filename*, so `[[World — entity/component/resource core]]` silently resolves to
     nothing once the file becomes `...entity_component_resource core.md`. A broken wikilink is a
     valid link to a not-yet-existing note, so it fails quietly. The writer warns when a title needs
     sanitizing; treat that warning as "rename this node". Same trap when you *retitle* a node
     mid-build: inbound links already written keep pointing at the old name.
   - **`sources`:** **every** file the node covers — repo-relative path plus that file's
     `git hash-object <path>` output, run from the repo root at the moment of writing. Exhaustive,
     not a sample: this is a **machine** field, and it is what makes Obsidian's search able to reach
     a node from any file it covers (searching a class name that appears in no node's prose still
     finds its node via this list). Do **not** trim it to a handful of "representative" files —
     doing so silently destroys that lookup, leaves the node unable to answer "which files am I
     about", and reduces hash verification to whatever survived the trim. Readability pressure
     belongs on `## Sources` below, never here.
   - **`sources_digest`:** `sha256` over the sorted `path:hash` lines of `sources` (see "Computing
     `sources_digest`" below). Lets a staleness check answer "has this node changed" by reading one
     field instead of every hash.
   - **`built_at`:** machine local time (`date '+%Y-%m-%d %H:%M'`) — never inferred.
   - **`stale`:** `false` — freshly built.
   - **Body:** `summary` (plain-English, the explanation a senior engineer would give walking
     someone through this subsystem), `crux` (the few lines that carry the actual logic — **authored
     as line numbers, stored as text**: you point, the writer slices, so composing is impossible at
     authoring time and nothing decays afterwards the way a stored line number would), `links` (typed
     Obsidian wikilinks to other nodes in this same namespace: `depends_on`, `part_of`, `uses`, or
     another type that fits better if one doesn't), a `## Sources` section, and an empty `## Notes`
     section.
   - **Never write crux code. Point at it and let the writer cut it out.** In the body, emit a
     directive instead of a code block:

     ```
     ## Crux
     <!-- crux: crates/matcher/src/lib.rs 412-419 -->
     ```

     `synapse-write-node.sh` slices those lines out of the file, fences them with a language guessed
     from the extension, appends a `path:start-end` provenance line, and records `crux_path` /
     `crux_lines` in frontmatter. It refuses the write if the path is not one the node claims, if the
     range runs past the end of the file, or if the span reaches 20 lines.

     This exists because a typed crux can be a paraphrase that merely *looks* like a quote — the
     invented `trait Matcher { /* no engine assumptions */ }` reads perfectly and is worth nothing. A
     rule saying "quote, don't compose" depends on compliance; pointing makes composing impossible,
     which is the same mechanics-are-scripts move as the rest of the write path.

   - **Ground the summary in what the codebase asserts about itself.** Prefer, in this order: a test
     (its name and assertions state behaviour that CI checks on every commit — the strongest evidence
     short of running the code), a doc comment or module header (the author's own claim of intent), and
     only then your own reading. Point at each piece of evidence, repeatably, anywhere in the body:

     ```
     <!-- grounded_in: src/test/java/PremiumTest.java 42-48 -->
     <!-- grounded_in: src/main/java/Premium.java 10-14 -->
     ```

     The writer records each as path + lines + sha256 of the sliced text in the `grounded_in`
     frontmatter list, then strips the directives — this is provenance, not display, so nothing is
     rendered and the prose stays readable. `synapse-query.sh grounding` later re-slices each range and
     compares, which turns "is this summary still true" from a judgement into a check.

     Why it matters more than it looks: a claim traced to a test or a doc comment is one the codebase
     made, so even a *wrong* doc comment beats an invented explanation — it is attributable and
     findable. What this is guarding against is the confident causal story assembled from a stray
     import ("output stays coherent because the printer is behind a mutex"), which reads exactly like
     understanding and can be false from the moment it is written.

     Not every sentence can be grounded, and that is expected. Architectural narrative and hard-won
     debugging findings have no test asserting them. Ground what can be grounded; do not manufacture
     evidence for the rest, and do not water down a true synthesis just to make it citable.

   - **`<!-- crux: none -->` is a real answer — use it.** A trivial data holder, a one-line
     delegation, or logic spread evenly with no focal point genuinely has no crux, and a subsystem
     node often has none either. A required field with no honest answer is exactly how a fabricated
     one appears, so say `none` rather than picking a span to fill the slot. If something adjacent is
     worth quoting instead, point at the module's own doc comment — that is an honest quote of
     something nearby, not a fabricated quote of the thing itself.
   - **Prefer claims about structure over claims about mechanism.** "These three printers implement
     the sink interface" is checkable and stays true; "the parallel path shares a printer behind a
     mutex, which is why output stays coherent" is the kind of causal story that is easy to assemble
     from a stray `use std::sync::Mutex` and wrong. Every later regeneration keeps the sentences the
     diff does not contradict, so a mechanism invented here is permanent. State one only after
     reading the code that implements it.
   - **`## Sources` is the human mirror of `sources`, aggregated rather than enumerated:** one line
     per owning directory or module with a file count, `LC_ALL=C` sorted. A node covering 941 files
     would otherwise put 75 KB of paths in front of a reader who wants to know which modules are
     involved — and the frontmatter already carries every path for search, so the mirror doesn't
     need to repeat them. Rewritten from `sources` on every write, never hand-edited. (Obsidian's
     Properties panel flattens the raw `sources` field into a truncated one-line string, which is
     why a mirror exists at all — but that is an argument for aggregating *the mirror*, not for
     trimming the field.)
   - **`## Notes` is human-authored only.** Claude never writes into it — not at build time, not at
     regeneration. It is created empty and preserved verbatim forever after.
   - **Fence the generated region.** Everything the generator owns sits between
     `<!-- synapse:generated:start -->` and `<!-- synapse:generated:end -->`; everything outside is
     re-emitted byte-for-byte. This is the mechanism behind the `## Notes` guarantee — without it,
     "preserved verbatim" is a promise with nothing enforcing it.

   ```yaml
   ---
   title: "World — entity/component/resource core"
   node_type: synapse-node
   project: eon
   sources:
     - path: eon_ecs/world.ml
       hash: <git hash-object output>
     - path: eon_ecs/world.mli
       hash: <git hash-object output>
     # ... every file the node covers, not a selection
   sources_digest: <sha256 over the sorted "path:hash" lines>
   stale: false
   built_at: "<now>"
   ---

   # World — entity/component/resource core
   <!-- synapse:generated:start -->

   ## Summary
   {plain-English explanation}

   ## Crux
   <!-- crux: {path a source line below claims} {start}-{end} -->
   {or `<!-- crux: none -->` when no single span carries it. The writer replaces
    this directive with the sliced code, so never write the code here yourself.}

   ## Links
   - depends_on [[Other Node Title]]
   - part_of [[Another Node Title]]

   ## Sources
   - `eon_ecs` (2)
   <!-- synapse:generated:end -->

   ## Notes

   ```

   ### Computing `sources_digest`

   Pin this exactly — a writer and a verifier computing it differently is a silent
   false-positive generator, and the point of the field is to be trusted without reading
   `sources` at all. Adopted from Graft's `sources_digest` so the two remain comparable:

   ```
   digest = sha256( "\n".join(sorted( f"{path}:{hash}" for each entry in sources )) )
   ```

   Sort the joined `path:hash` lines themselves (not the paths, then the hashes), `LC_ALL=C`,
   newline-separated, no trailing newline.

   `project` is the repo name resolved above, not the task-prefix scheme.

6. **Write `_index.json`** — mechanics, run `synapse-build-index.sh`. It emits
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

7. **Write `synapse/{repo}@{branch}/Index.md`** — mechanics, run `synapse-build-project-index.sh`. It
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
3. For each unassigned path: try `~/.claude/bin/synapse-tags.sh {path}` first (same exit-code
   handling as the first-time build's per-file pass above) as a fast pre-classification signal,
   falling back to a full read for genuinely ambiguous cases. Classify against the existing node
   list.
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
