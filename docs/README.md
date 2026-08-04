# Documentation

How the pieces in this repo fit together, for anyone (including future-you) who wants the fuller
picture beyond the individual command/hook/skill files. Each doc below stands alone; read whichever
one matches what you're trying to understand.

- **[second-brain.md](second-brain.md)** — the memory system itself: the Obsidian vault, its
  folder layout, and the three hooks that keep it alive across sessions (`SessionStart` injection,
  the `Stop` nudge, and vault→git auto-commit).
- **[synapse.md](synapse.md)** — the per-repo semantic code graph: the two-tier staleness model,
  `/synapse-init`, the `synapse-node` Tier 2 skill, `synapse-query.sh` (projected reads, so a node's
  exhaustive `sources` never enters a context window), and the optional tree-sitter acceleration
  layer. Also the rule that keeps it language-agnostic — mechanics are scripts, interpretation is the
  model, `manifest.tsv` is the seam — and why the "never a context read" constraint is symmetric,
  which is what forces the write path to be scripted too.
- **[design-task-workflow.md](design-task-workflow.md)** — the design-note → task-note pairing
  pipeline: `/sb-design-note`, `/sb-task-note`, the `sb-task` status-tracking skill, and the
  optional GitHub-issue mirror.
- **[scripts.md](scripts.md)** — reference for every `claude/bin/*.sh`: purpose, usage, arguments and
  exit codes. **Generated**, by `generate-scripts-reference.sh`, from the same header block each
  script prints for `--help` — so it cannot describe a script that has moved on. Run the generator
  after editing a header; `--check` is wired into the test suite. It carries no rationale on purpose:
  that belongs in the docs above, and duplicating it in two places is how the copies start to differ.

Diagrams live in [diagrams/](diagrams/), one per doc above, embedded as PNGs exported by hand from
ExcalidrawZ:

- `diagrams/second-brain-overview.png`
- `diagrams/synapse-tiers.png`
- `diagrams/design-task-workflow.png`
- `diagrams/synapse-pipeline.png` — every script in one picture: which step of a build each one
  owns, what it writes, and where the model's two contributions enter. Laid out as three lanes
  (model judgment / script mechanics / vault artifacts) so the seam is visible as the only place
  arrows cross from the first lane into the second. It opens `synapse.md` as that doc's overview,
  with `synapse-tiers.png` sitting further down in the staleness section it illustrates.

The matching `.excalidraw` source files are also in that folder — a rough first-pass layout, not
meant as the final art. Open one in ExcalidrawZ (or excalidraw.com) as a starting point, or ignore
it and draw fresh; either way, export the result as a same-named `.png` for the docs to embed.

## Why these three pieces, together

They're independent systems that happen to share one host (the vault) and one consumer (Claude
Code in this repo's sessions):

- The **second brain** is the durable, cross-project knowledge base — notes that outlive any one
  session or repo.
- **Synapse** is a per-repo accelerant layered on top of it — instead of re-exploring a codebase
  from scratch every session, Claude Code gets a small, LLM-authored map of it, stored the same way
  any other note is.
- The **design/task workflow** is how a piece of thinking turns into tracked, resumable work,
  living in the same vault so it's searchable alongside everything else.

None of the three requires the others. A project can use the second brain without ever running
`/synapse-init`; a design note can conclude as `Reference` with no task attached; Synapse doesn't
care whether the repo it's initialized in has any design notes at all.
