# Documentation

How the pieces of Synapse fit together, for anyone (including future-you) who wants the fuller picture
beyond the individual command, hook and skill files. Each doc below stands alone; read whichever one
matches what you're trying to understand.

- **[second-brain.md](second-brain.md)** — **Synapse Vault**: the Obsidian vault itself, its folder
  layout, and the three hooks that keep it alive across sessions (`SessionStart` injection, the `Stop`
  nudge, and vault→git auto-commit). The filename still carries this project's earlier name.
- **[synapse.md](synapse.md)** — **Synapse Graph**: the per-repo semantic code graph. The two-tier
  staleness model, `/synapse-init`, the `synapse-node` Tier 2 skill, `synapse-query.sh` (projected
  reads, so a node's exhaustive `sources` never enters a context window), the unfabricable `crux`,
  grounded summaries, opportunistic correction, and the optional tree-sitter acceleration layer. Also
  the rule that keeps it language-agnostic — mechanics are scripts, interpretation is the model,
  `manifest.tsv` is the seam — and why the "never a context read" constraint is symmetric, which is
  what forces the write path to be scripted too.
- **[design-task-workflow.md](design-task-workflow.md)** — the design-note → task-note pipeline that
  runs on top of the Vault: `/sb-design-note`, `/sb-task-note`, the `sb-task` status-tracking skill,
  and the optional GitHub-issue mirror.
- **[scripts.md](scripts.md)** — reference for every **Synapse Tools** script in `claude/bin/`:
  purpose, usage, arguments and exit codes. **Generated**, by `generate-scripts-reference.sh`, from the
  same header block each script prints for `--help` — so it cannot describe a script that has moved on.
  Run the generator after editing a header; `--check` is wired into the test suite. It carries no
  rationale on purpose: that belongs in the docs above, and duplicating it in two places is how the
  copies start to differ.

Diagrams live in [diagrams/](diagrams/), embedded as PNGs exported by hand from ExcalidrawZ:

- `diagrams/second-brain-overview.png` — the Vault and its hooks.
- `diagrams/synapse-tiers.png` — the Graph's two staleness tiers and the tree-sitter layer.
- `diagrams/design-task-workflow.png` — the design-note → task-note pipeline.
- `diagrams/synapse-pipeline.png` — every script in one picture: which step of a build each one owns,
  what it writes, and where the model's two contributions enter. Laid out as three lanes (model
  judgment / script mechanics / vault artifacts) so the seam is visible as the only place arrows cross
  from the first lane into the second. It opens `synapse.md` as that doc's overview, with
  `synapse-tiers.png` sitting further down in the staleness section it illustrates.

The matching `.excalidraw` source files are also in that folder — a rough first-pass layout, not meant
as the final art. Open one in ExcalidrawZ (or excalidraw.com) as a starting point, or ignore it and
draw fresh; either way, export the result as a same-named `.png` for the docs to embed.

## The three components, and why they are separate

Synapse is three things sharing one host and one consumer — the Vault stores everything, and Claude
Code is the only thing that reads it:

- **Synapse Vault** is the durable, cross-project knowledge base: notes that outlive any one session or
  repo.
- **Synapse Graph** is a per-repo accelerant layered on top of it. Instead of re-exploring a codebase
  from scratch every session, Claude Code gets a small, LLM-authored map of it, stored the same way any
  other note is.
- **Synapse Tools** are the scripts, commands, skills and hooks that build and maintain both — and the
  only part this repository actually ships.

The Vault and the Graph do not require each other. A project can use the Vault without ever running
`/synapse-init`; a design note can conclude as `Reference` with no task attached; the Graph does not
care whether the repo it is initialized in has any notes at all. The Tools are what make either usable
from inside a session, which is why the constraint that shapes them — a node's exhaustive `sources` can
neither be read into a context window nor emitted from one — ends up dictating so much of the design.
