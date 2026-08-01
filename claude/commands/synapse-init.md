# Synapse Init: Build or Refresh a Repo's Code-Graph Namespace

Builds a repo's Synapse namespace in the second-brain vault — a small set of LLM-authored node
notes (summary + crux + typed links per subsystem/concept) plus the two derived projections that
keep it cheap to consult and keep stale (`_index.json`, `synapse/{repo-name}/Index.md`). Design
reference: [[sb — Synapse (Obsidian code-graph layer)]], compiled as [[sb-001 — Synapse
implementation]].

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

## Resolving repo context

Every step below needs the same three facts, resolved once up front:

1. **Repo root:** `git rev-parse --show-toplevel`.
2. **Repo name:** basename of the repo root. This is the Synapse namespace key
   (`synapse/{repo-name}/`) — a plain, readable folder name, not a collision-proof key (see the
   design note's Alternatives for why). Distinct from the short task-prefix scheme
   (`project-name=prefix`) used by `/sb-note`/`/sb-design-note` — unrelated
   conventions that happen to both involve the word "project."
3. **Remote:** `git remote get-url origin` (or any configured remote if `origin` doesn't exist —
   pick the first one `git remote` lists). If the repo has no remote at all, fall back to the
   repo root's absolute path. This is the verification field written into the per-project
   `Index.md` and checked by the `SessionStart` hook before it ever injects a pointer.

## Already initialized?

Check whether `synapse/{repo-name}/Index.md` exists (`mcp__obsidian__vault_list` on
`synapse/{repo-name}/`, or a direct `vault_read` attempt).

- **Doesn't exist** → this is a first-time build. Go to "First-time build" below.
- **Exists, `remote` frontmatter matches** the resolved remote/path → this namespace already
  belongs to this repo. Nothing here needs a full rebuild (regeneration is handled lazily at read
  time — see the design note's Generation & Regeneration section); the only thing `/synapse-init`
  still does for an already-initialized project is the manual "process it now" sweep of
  `_unassigned` — go to "Re-running on an initialized project" below.
- **Exists, `remote` mismatches** → `synapse/{repo-name}/` belongs to a *different* repo that
  happens to share a basename. Do not touch it. Stop and tell the user plainly: "A Synapse
  namespace already exists at `synapse/{repo-name}/` for a different remote/path
  (`{existing remote}`) — this repo's remote is `{resolved remote}`. Refusing to overwrite; rename
  one of the two repos, or pick a different resolution, before initializing here." This is the
  same detect-and-flag asymmetry the `SessionStart` hook uses — contaminating one project's graph
  with another's is worse than a blocked command.

## First-time build

1. **Enumerate files:** `git ls-files` from the repo root — tracked files only, which gets
   `.gitignore` exclusion for free and matches what's actually worth summarizing (build output,
   dependencies, etc. are never tracked). Drop obvious binary/generated files a repo-relative
   `.gitattributes`-style judgment call would also drop (images, lockfiles with no prose value,
   `dist/`-style build output that somehow got tracked) — use judgment, this doesn't need to be
   exhaustive.
2. **Read hint files, if present:** `CLAUDE.md` and `README.md` at the repo root. These bias the
   clustering pass in step 4 — they are never treated as authoritative structure, and the pass can
   and should diverge from them if the files themselves disagree. No other project-specific doc
   convention (e.g. a `docs/design/` folder) gets this treatment — see the design note's
   Alternatives for why that was rejected.
3. **Per-file summary pass:** for each enumerated file, read it and produce a short internal
   summary of what it contains/does. This is scaffolding for clustering, not the node output
   itself — don't write these anywhere.
4. **Cluster into nodes:** group the per-file summaries into a few dozen readable nodes, not one
   per file — same density Graft aims for. A node is a subsystem or concept, not a file; a file may
   legitimately belong to more than one node's `sources` when it's genuinely load-bearing for two
   concepts (many-to-many is intentional, not an oversight). Use the `CLAUDE.md`/`README.md`
   content read in step 2 as a bias on grouping and naming, never as a boundary the files
   themselves don't support.
5. **Write each node.** For every cluster, write `synapse/{repo-name}/{Node Title}.md`:

   - **Filename/title:** short, senior-engineer-style description of the concept (e.g. "World —
     entity/component/resource core"). Sanitize filesystem-illegal characters (`/ : * ? " < > |`).
   - **`sources`:** repo-relative paths plus each file's `git hash-object <path>` output, run from
     the repo root, at the moment of writing.
   - **`built_at`:** machine local time (`date '+%Y-%m-%d %H:%M'`) — never inferred.
   - **`stale`:** `false` — freshly built.
   - **Body:** `summary` (plain-English, the explanation a senior engineer would give walking
     someone through this subsystem), `crux` (the few lines that carry the actual logic, stored as
     *text*, not line numbers — line numbers drift, quoted text survives it), `links` (typed
     Obsidian wikilinks to other nodes in this same namespace: `depends_on`, `part_of`, `uses`, or
     another type that fits better if one doesn't), and an empty `## Notes` section (freeform,
     preserved verbatim across every future regeneration — never overwritten by the regen
     procedure).

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
   stale: false
   built_at: "<now>"
   ---

   # World — entity/component/resource core

   ## Summary
   {plain-English explanation}

   ## Crux
   ```{lang}
   {the few lines that carry the actual logic, quoted verbatim}
   ```

   ## Links
   - depends_on [[Other Node Title]]
   - part_of [[Another Node Title]]

   ## Notes

   ```

   `project` is the repo name resolved above, not the task-prefix scheme.

6. **Write `_index.json`:** `synapse/{repo-name}/_index.json`, mapping every source path used
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

7. **Write `synapse/{repo-name}/Index.md`:** the per-project map — node titles, one-line
   summaries, and `built_at`, plus the `remote` frontmatter field resolved above.

   ```yaml
   ---
   title: "{repo-name} — Synapse index"
   node_type: synapse-index
   project: {repo-name}
   remote: "{resolved remote or path}"
   built_at: "<now>"
   ---

   # {repo-name} — Synapse index

   - [[World — entity/component/resource core]] — {one-line summary} (built {built_at})
   - ...
   ```

## Re-running on an initialized project

This is the manual fallback for the `_unassigned` sweep that normally rides along on any lazy
regeneration (see the design note's Node Granularity & Grouping) — for a project that's gone fully
dormant and has no other regeneration event to piggyback on. It does **not** re-cluster or rebuild
existing nodes.

1. Read `synapse/{repo-name}/_index.json`'s `_unassigned` array. Empty → report "Nothing
   unassigned, nothing to do" and stop.
2. Read `synapse/{repo-name}/Index.md` for the current node list (titles + summaries).
3. For each unassigned path: read the file, classify it against the existing node list.
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
  `SessionStart` hook will now pick this project up automatically (once the hook itself is wired —
  see [[sb-001 — Synapse implementation]] if it isn't yet).
- **Re-run:** report how many unassigned files were resolved, how many remain, and to which nodes
  anything was attached.
- **Namespace collision:** the refusal message from "Already initialized" above — nothing is
  written.

## Integration

- Nodes and projections written here are read by Claude directly at Synapse read time (Tier 2
  staleness check + regeneration — a procedure, not a hook, documented alongside this command) and
  flagged stale by the `PostToolUse` hook on every subsequent edit to a source file.
- The `SessionStart` hook's pointer injection depends on this command having run at least once —
  it does a plain existence check on `synapse/{repo-name}/Index.md` and does nothing if this was
  never run.
