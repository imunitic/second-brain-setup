# Obsidian Design Note: Cross-Project Personal Design Discussion

The Obsidian-vault counterpart to `/design-note` — same free-form "think it through out loud"
pipeline, but the note lives in the second-brain vault instead of the current repo's `docs/notes/`.
Use it when the design conversation isn't (or shouldn't be) tied to one repo's private-note
lifecycle — it's findable from any project immediately, with no separate pointer-note step, because
the vault itself is already the cross-project store.

Not every design discussion ends with something to build. See `Status: Reference` below for the
"no implementation attached" ending — same distinction `/design-note` makes.

## Usage

```
/obsidian-design-note "topic"           # Start or resume a design discussion
/obsidian-design-note --continue        # Resume an incomplete design note
/obsidian-design-note --elevate "topic" # Promote a concluded note into the CURRENT repo's Record
/obsidian-design-note --list            # List every Obsidian design note, regardless of status
```

## When to use this vs. `/design-note` vs. `/design`

| Use `/obsidian-design-note` when... | Use `/design-note` when... | Use `/design` when... |
|---|---|---|
| Might be relevant beyond this one repo, or you want it searchable from anywhere | Purely local to this repo's work, fine being invisible elsewhere | Team needs to see the decision |
| Fine living in the shared personal vault | Fine with a private, gitignored note in this repo | Feature will definitely ship, others are affected |

Both private variants are equally throwaway-able — the difference is *where* the throwaway lives,
not how seriously to take the conversation.

## Prerequisites

- Requires the `obsidian` MCP server (`mcp__obsidian__*` tools). If unreachable, say so and stop —
  there is no local-file fallback for this command, unlike `/design-note`.
- If `designs/` doesn't exist in the vault yet, `mcp__obsidian__vault_write` creates it implicitly on
  first write — but add a `designs/` entry to the vault's `Index.md` folder layout in the same
  action (per the second-brain folder-layout rule: a new top-level folder must never fall behind the
  index).

## Determining the project

Every design note is tagged with the project it belongs to — both in the title
(`{PROJECT} — {Topic}`) and as `project: {prefix}` in frontmatter (the same short prefix
`/obsidian-note --task` uses for task IDs, e.g. `sbu`, `ecs`) — so a flat `designs/` folder still
reads clearly, and both note kinds can be filtered together via `search_query`.

1. Infer the project from the current repo: check its project `CLAUDE.md` (title/"About" section) or
   `git remote`.
2. If it matches a known project/prefix pair (see `/obsidian-note`'s "Resolving a missing task ID"
   list — currently `eon`/`ecs`, `SBU`/`sbu`), use it.
3. If it doesn't match anything known, ask the user for a short project tag. If this turns out to be
   a recurring project (not a one-off), add it to `/obsidian-note`'s known list too — otherwise a
   later `/obsidian-task-note` compile for the same topic will have to ask again from scratch.

## Handling Arguments

**No arguments:**
1. Check for incomplete design notes: search `designs/` (via `mcp__obsidian__vault_list` +
   `vault_read`, or `search_query` scoped to the `designs/` path) for notes whose `## Status` line
   reads `Discussing`.
2. If found: show a short state summary — title and current section — and offer to resume.
3. If none: ask "What are we designing?"

**With a topic:**
1. Search first — `mcp__obsidian__search_simple` for the topic text across `designs/` (per the
   second-brain rule: link/reuse over duplicate). Also check for an obvious title match.
2. If found with `Status: Discussing` → ask "Resume this design?" or "Start fresh?"
3. If found with `Status: Ready` → ask "Already marked Ready. Reopen to revise, or start a new note?"
4. If found with `Status: Reference` → ask "This concluded as Reference (no implementation intended).
   Reopen to revise, or is that still accurate?"
5. Otherwise: start a new design note (see "Determining the project" above for the title/frontmatter
   tag).

**--continue:**
1. Find notes with `Status: Discussing` (same lookup as "No arguments").
2. Multiple → list them, ask which to continue.
3. One → resume it.
4. None → "No incomplete design note found. Start one with `/obsidian-design-note \"topic\"`."

**--elevate "topic":** see "Elevating to a Record" below.

**--list:**
1. `mcp__obsidian__vault_list` on `designs/`, then `vault_read` each (or a `search_query` scoped to
   that path) to pull title and `## Status`.
2. None found → "No design notes yet. Start one with `/obsidian-design-note \"topic\"`."
3. Group into **Active** (`Discussing`, `Ready`) and **Closed** (`Reference`) — active first. Same
   output shape as `/design-note --list` (title + status in backticks, not bold).

---

## Workflow

Identical to `/design-note`'s: free-form conversation, no fixed step order. Create the note on the
first substantive answer and update it after every meaningful exchange — don't wait until the end.

Angles worth covering (skip whatever's not relevant):
- What problem are we solving, and why now?
- What's the chosen approach? If there were real alternatives, a one-line "why not" for each.
- What are the hard constraints?
- Anything risky, or that needs deciding now vs. can be deferred?

### Concluding: Ready or Reference

Same rule as `/design-note`:

- **Something to build** → `Status: Ready`. Confirm: "Design note ready: `designs/{title}.md`.
  Whenever you're ready to implement, generate the task with
  `/obsidian-task-note \"{topic}\"` — no rush, nothing here expires."
- **Nothing to build** → `Status: Reference`. Confirm: "Design note concluded as Reference:
  `designs/{title}.md`. No task note needed."

If genuinely unsure which, ask the user directly.

There is no closing/renaming step here (unlike `/design-note`'s `.open.md` → `.md`) — nothing reads
these notes automatically at session start, so the `## Status` line is the only lifecycle marker
that matters. It simply stays `Ready`/`Reference` indefinitely.

---

## Design Note Format

```
---
title: "{PROJECT} — {Topic}"
project: {prefix}
created: "{now}"
---

# {PROJECT} — {Topic}

## Status
Discussing | Ready | Reference

## Problem
{What are we solving, why does it matter, why now}

## Approach
{Chosen approach}

### Alternatives considered (optional)
- {Option}: why not

## Constraints
{Hard constraints, non-negotiables}

## Open Questions (optional)
- {Anything deferred or unresolved}
```

Fetch machine local time for `created` (`date '+%Y-%m-%d %H:%M'`) — never infer it.

No `Notes`/changelog section, same reasoning as `/design-note`: either this gets elevated (git commit
history becomes the changelog) or it stays a small, single-conclusion note.

## Filename

`designs/{PROJECT} — {Topic}.md` — sanitize filesystem-illegal characters (`/ : * ? " < > |`). No
slug, no numbering — Obsidian filenames are the title itself.

---

## Elevating to a Record (`--elevate`)

Promotes a concluded Obsidian design note into the **current repo's** `docs/records/` — the same
bridge `/design-note --elevate` provides, just reading from the vault instead of `docs/notes/`.

### Prerequisites

- Find the matching design note. Not found → "No design note found for '{topic}'."
- `Status: Discussing` → "Still in Discussing — finish the conversation first (mark it Ready or
  Reference), then elevate."
- If no `docs/records/` directory exists in the current repo: create it.

### What to do

1. Carry the note's own sections over close to verbatim (Problem stays Problem, Approach becomes the
   decision/rationale, etc.) — check this repo's actual `docs/records/*.md` for house style first;
   don't force `/design`'s Options/Solution/Stories template onto a repo that doesn't use it (see
   `/design-note --elevate`'s "What NOT to do" for the reasoning, unchanged here).
2. Assign the next Record number: scan `docs/records/` for the highest `{NNN}-*.md` and increment.
   Slug the topic for the filename (lowercase-hyphenated).
3. Title: `# Record {NNN}: {Title}`.
4. If a compiled task note exists (linked via the `> Compiled task:` annotation — see
   `/obsidian-task-note`), ask whether to fold its checklist into the Record as a plain
   `## Execution Plan` section, noting it's a snapshot ("see `[[{task note}]]` for live status").
5. Write `docs/records/{NNN}-{slug}.md`.
6. Annotate the Obsidian note: add `> Elevated to Record {NNN} on {today's date}.` near the top (via
   `mcp__obsidian__vault_patch`). Don't delete or close it — it's the discussion trail, and it's
   already durable in the vault regardless.
7. Confirm:
   ```
   Elevated to Record {NNN}: docs/records/{NNN}-{slug}.md
   Source note: designs/{title}.md (annotated)

   Add a Current Status / Future row in this repo's CLAUDE.md if this should be tracked as active
   work — that's not automatic.
   ```

---

## Integration

- `/obsidian-task-note "{topic}"` reads the matching `Ready` note as its only input, same restriction
  `/task-note` places on `/design-note`.
- Fully separate from `/design-note`/`docs/notes/` — a topic lives in exactly one of the two systems,
  never both. Choose per "When to use this vs." above before starting, not after.
- `--elevate` is the one bridge to `docs/records/`: manual, one-directional (note → Record).

---

## Example

```
User: /obsidian-design-note "rollup direct storage"

Claude: [searches designs/ for existing matches — none found]

        What are we designing?

User: Replacing the AggregatingMergeTree rollup resolution with direct-value storage.

Claude: [creates designs/SBU — Rollup direct storage.md, Status: Discussing]

        What's driving this over just tuning the current argMaxMerge query?
...
User: The resolution cost alone dominates the query, tuning won't fix that. Mark it ready.

Claude: Design note ready: designs/SBU — Rollup direct storage.md.
        Generate the task with /obsidian-task-note "rollup direct storage" whenever you're ready.
```
