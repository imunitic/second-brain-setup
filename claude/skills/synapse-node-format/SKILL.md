---
name: synapse-node-format
description: The contract for a Synapse code-graph node — frontmatter fields, the crux pointer, `## Links`, `grounded_in`, `## Sources`, and what `synapse-write-node.sh` adds or refuses. Load before authoring or regenerating any node, whether from /synapse-init's first build, /synapse-rebuild's triage, or the synapse-node skill's lazy regeneration. Not for reading the graph (that is synapse-query) or for task notes in the vault (that is synapse-task).
---

# What a node is, and how to author one

Every component that writes a node loads this: `/synapse-init` (first build), the `synapse-node`
skill (Tier 2 lazy regeneration), and `/synapse-rebuild` (reseat, patch, re-orient).

All three write the same artifact, so the format belongs in one place rather than being restated
wherever it is used. What stays with each caller is what is genuinely specific to it — the skill's
traps when *re*-authoring an existing node, rebuild's triage classes — not the contract itself.

`synapse-write-node.sh` is the enforcement. Where this document states a rule the writer already
refuses to break, that is deliberate and the script is the authority; this describes the artifact so
a reader knows what to produce, not so anyone hand-builds one.

Author the prose only — put each node's content in
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

The driver strips that frontmatter and the line becomes the node's `summary` field, which
`synapse-build-project-index.sh` reads back to build the index bullet. Write it *for the index* — it has to distinguish this node
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

`project` is the repo half of the namespace key — `synapse_repo_name` in `~/.claude/bin/synapse-identity.sh`, not the task-prefix scheme that `/synapse-note` uses. The writer fills it in; it is described here so the field's meaning is documented once.

