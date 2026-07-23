# Obsidian Task Note: Compile a Design into a Tracked Checklist

The Obsidian-vault counterpart to `/task-note` — compiles a `Ready` design note (from
`/obsidian-design-note`) into a single tracked task, using the vault's existing task-tracking
machinery instead of a bespoke format: creation goes through `/obsidian-note --task`, and status
transitions from then on belong entirely to the `obsidian-task` skill. This command's only job is
the compile step — turning a design into an ordered checklist — not tracking progress itself.

Unlike `/task-note`, there is no separate multi-task file-level state (`Planned`/`In Progress`/
`Review`/`Done` across several `### Task N` entries). One design compiles into **one** task note,
one `task_id`, and the checklist items *are* the steps — matching how every other task in the vault
already works (see `obsidian-task`'s "Task file structure").

## Usage

```
/obsidian-task-note "topic"    # Compile the task note for a Ready design note
```

No `--continue`/`--list` here — once created, the task note's own progress (checked items,
`status:` frontmatter) is what `/obsidian-note --list` and the `obsidian-task` skill already track.
Use those instead of reinventing a parallel view.

## Prerequisites

- Requires a matching Obsidian design note (`designs/`) with `Status: Ready`.
- No matching note → "No Ready design note found for '{topic}'. Run
  `/obsidian-design-note \"{topic}\"` first." Never generate a checklist from scratch.
- Matching note but `Status: Discussing` → "Design note for '{topic}' is still in Discussing. Finish
  it first."
- Matching note but `Status: Reference` → "Design note for '{topic}' concluded as Reference —
  nothing to compile. Reopen it with `/obsidian-design-note \"{topic}\"` and mark it Ready if that's
  changed."
- A task note already exists for this design (check the design note's `> Compiled task:` annotation,
  or `search_query` for a `projects/` note linking to it) → show its current state (title, `status:`,
  checked/total) and ask: view it, or recompile fresh (only on explicit confirmation — recompiling
  discards the old checklist's progress, since the new one gets a fresh `task_id`).

## Compiling the checklist

1. Read the design note in full.
2. Break the approach into an ordered list of small, sequential, independently-completable steps —
   same judgment `/task-note` step 4 uses.
3. For each step, write it the way `obsidian-task`'s own checklist convention expects: a short
   `- [ ] {Do}` line; for substantive steps (type definitions, API surfaces, interface signatures)
   add a one-line nested description plus a fenced code block showing the exact interface, per that
   skill's "Inline code examples in checklist items". Don't invent separate Files/Tests/AC fields —
   fold what matters into the item's own description instead (e.g. "...; test: X returns Y").
4. Note explicit exclusions — things a reasonable implementer might also attempt that are out of
   scope — for the `## Notes` section below, not a separate heading.

## Creating the note

Follow `/obsidian-note`'s task-mode procedure exactly (its "Creating the note" section) — don't
duplicate that scaffolding here, just supply its inputs:

- **Title:** a short, plain description of the compiled plan (e.g. "Rollup direct storage
  implementation") — `/obsidian-note --task` resolves the project prefix and `task_id` and prepends
  them itself.
- **Project:** derive from the source design note's `project:` frontmatter. If it maps to a known
  prefix (see `/obsidian-note`'s "Resolving a missing task ID" list), supply it directly instead of
  re-asking. If it's genuinely new, let that command's normal resolution question run.
- **Body:** the checklist from "Compiling the checklist" above, under the single top-level heading —
  exactly the structure `obsidian-task`'s "Task file structure" requires (no `## Step` sub-headings).
- **`## Notes` (pre-implementation):** populate per `obsidian-task`'s own convention —
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
IN-PROGRESS → REVIEW) happen automatically via the `obsidian-task` skill once work starts — this
command doesn't set or watch that field itself.

## Integration

- Reads `/obsidian-design-note`'s `Ready` output only — never invents a design.
- Delegates note creation to `/obsidian-note --task` and status tracking to the `obsidian-task` skill
  — this command owns only the design → checklist compile step.
- Independent of `/task-note`/`docs/notes/` — a topic lives in one system or the other, not both.

---

## Example

```
User: /obsidian-task-note "rollup direct storage"

Claude: [reads designs/SBU — Rollup direct storage.md, Status: Ready]
        [no existing linked task note]

        Compiled checklist:
        - [ ] Add ReplacingMergeTree target table for the daily rollup
        - [ ] Point the rollup MV at the new table instead of AggregatingMergeTree
        - [ ] Migrate existing daily/monthly rollups (drop+recreate, sort-key change)
        - [ ] Update the 5 retrofitted dashboards' rollup queries to drop argMaxMerge

        Project already known: SBU → sbu-005.

        Created: projects/sbu-005 — Rollup direct storage implementation.md
        Linked back from designs/SBU — Rollup direct storage.md.

        Status transitions happen automatically via the obsidian-task skill once you start work.
```
