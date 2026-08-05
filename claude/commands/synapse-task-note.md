# Second Brain Task Note: Compile a Design into a Tracked Checklist

Compiles a `Ready` design note (from `/synapse-design-note`) into a single tracked task, using the
vault's existing task-tracking machinery instead of a bespoke format: creation goes through
`/synapse-note --task`, and status transitions from then on belong entirely to the `synapse-task`
skill. This command's only job is the compile step — turning a design into an ordered checklist —
not tracking progress itself.

One design compiles into **one** task note, one `task_id`, and the checklist items *are* the
steps — matching how every other task in the vault already works (see `synapse-task`'s "Task file
structure").

## Usage

```
/synapse-task-note "topic"    # Compile the task note for a Ready design note
```

No `--continue`/`--list` here — once created, the task note's own progress (checked items,
`status:` frontmatter) is what `/synapse-note --list` and the `synapse-task` skill already track.
Use those instead of reinventing a parallel view.

## Prerequisites

- Requires a matching Obsidian design note (`designs/`) with `Status: Ready`.
- No matching note → "No Ready design note found for '{topic}'. Run
  `/synapse-design-note \"{topic}\"` first." Never generate a checklist from scratch.
- Matching note but `Status: Discussing` → "Design note for '{topic}' is still in Discussing. Finish
  it first."
- Matching note but `Status: Reference` → "Design note for '{topic}' concluded as Reference —
  nothing to compile. Reopen it with `/synapse-design-note \"{topic}\"` and mark it Ready if that's
  changed."
- A task note already exists for this design (check the design note's `> Compiled task:` annotation,
  or `search_query` for a `projects/` note linking to it) → show its current state (title, `status:`,
  checked/total) and ask: view it, or recompile (only on explicit confirmation — recompiling rewrites
  the checklist, so any progress on items that no longer exist is lost).

  **A recompile updates the existing note in place. It never creates a second one and never bumps
  the `task_id`.** One design has exactly one task note for its whole life; a design that gets
  revised mid-implementation is the normal case, not a new task. Preserve `task_id`, `created`,
  `status`, the filename, and any `## Notes` content the human added; replace the checklist and the
  pre-implementation notes. Carry forward `- [x]` marks for items that survive the recompile
  unchanged — work already done doesn't become undone because the plan around it grew.

  Record *why* in the note itself, in one line at the top of the body: what the old plan got wrong
  and what changed. A recompiled task with no explanation reads like a plan that was always this
  shape, which hides the fact that implementation found a gap.

## Compiling the checklist

1. Read the design note in full.
2. Break the approach into an ordered list of small, sequential, independently-completable steps.
3. For each step, write it the way `synapse-task`'s own checklist convention expects: a short
   `- [ ] {Do}` line; for substantive steps (type definitions, API surfaces, interface signatures)
   add a one-line nested description plus a fenced code block showing the exact interface, per that
   skill's "Inline code examples in checklist items". Don't invent separate Files/Tests/AC fields —
   fold what matters into the item's own description instead (e.g. "...; test: X returns Y").
4. Note explicit exclusions — things a reasonable implementer might also attempt that are out of
   scope — for the `## Notes` section below, not a separate heading.

## Creating the note

Follow `/synapse-note`'s task-mode procedure exactly (its "Creating the note" section) — don't
duplicate that scaffolding here, just supply its inputs:

- **Title:** a short, plain description of the compiled plan (e.g. "Rollup direct storage
  implementation") — `/synapse-note --task` resolves the project prefix and `task_id` and prepends
  them itself.
- **Project:** derive from the source design note's `project:` frontmatter — that prefix is already
  resolved (the design note went through `/synapse-design-note`'s resolution when it was created,
  which reads/appends `~/.claude/synapse-projects.conf`), so supply it directly instead of
  re-deriving or re-asking. Never hardcode a specific project/prefix pair in this command's own
  instructions — the conf file is machine-local and deliberately outside the portable
  Synapse package, so projects from unrelated contexts (e.g. personal vs. work) must
  never end up in the same place.
- **Body:** the checklist from "Compiling the checklist" above, under the single top-level heading —
  exactly the structure `synapse-task`'s "Task file structure" requires (no `## Step` sub-headings).
- **`## Notes` (pre-implementation):** populate per `synapse-task`'s own convention —
  - Design reference: `[[{design note title}]]`
  - Key constraints the implementor must not miss
  - Deliberate exclusions (from step 4 above) and why

## Linking back

After creation, patch the design note: add `> Compiled task: [[{task note title}]]` near the top
(via `mcp__obsidian__vault_patch`) — a small annotation line, same idea as any other cross-reference
you'd drop near a note's title. This is a one-time link; the design note's `Status` itself does not
change and does not need to track the task's progress — Obsidian's own backlinks panel already
surfaces the live task note from the design note, and the task's `status:` frontmatter is the
authoritative progress signal from here on.

## Confirm

Report the created path and title, and remind the user that `status:` transitions (TODO →
IN-PROGRESS → REVIEW) happen automatically via the `synapse-task` skill once work starts — this
command doesn't set or watch that field itself.

## Integration

- Reads `/synapse-design-note`'s `Ready` output only — never invents a design.
- Delegates note creation to `/synapse-note --task` and status tracking to the `synapse-task` skill
  — this command owns only the design → checklist compile step.

---

## Example

```
User: /synapse-task-note "rollup direct storage"

Claude: [reads designs/{PROJECT} — Rollup direct storage.md, Status: Ready]
        [no existing linked task note]

        Compiled checklist:
        - [ ] Add ReplacingMergeTree target table for the daily rollup
        - [ ] Point the rollup MV at the new table instead of AggregatingMergeTree
        - [ ] Migrate existing daily/monthly rollups (drop+recreate, sort-key change)
        - [ ] Update the 5 retrofitted dashboards' rollup queries to drop argMaxMerge

        Project already known: {PROJECT} → {prefix}-005.

        Created: projects/{prefix}-005 — Rollup direct storage implementation.md
        Linked back from designs/{PROJECT} — Rollup direct storage.md.

        Status transitions happen automatically via the synapse-task skill once you start work.
```
