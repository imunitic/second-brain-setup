# Second Brain Design Note: Cross-Project Personal Design Discussion

A free-form "think it through out loud" pipeline for a design conversation, written to Synapse
Vault rather than any one repo. Use it when the design conversation isn't (or shouldn't be) tied
to one repo's lifecycle — it's findable from any project immediately, with no separate
pointer-note step, because the vault itself is already the cross-project store.

Not every design discussion ends with something to build. See `Status: Reference` below for the
"no implementation attached" ending.

## Usage

```
/synapse-design-note "topic"           # Start or resume a design discussion
/synapse-design-note --continue        # Resume an incomplete design note
/synapse-design-note --list            # List every Obsidian design note, regardless of status
```

## Prerequisites

- Requires the `obsidian` MCP server (`mcp__obsidian__*` tools). If unreachable, say so and stop —
  there is no local-file fallback for this command.
- If `designs/` doesn't exist in the vault yet, `mcp__obsidian__vault_write` creates it implicitly on
  first write — but add a `designs/` entry to the vault's `Index.md` folder layout in the same
  action (per the Synapse Vault folder-layout rule: a new top-level folder must never fall behind the
  index).

## Determining the project

Every design note is tagged with the project it belongs to — both in the title
(`{PROJECT} — {Topic}`) and as `project: {prefix}` in frontmatter (the same short prefix
`/synapse-note --task` uses for task IDs) — so a flat `designs/` folder still reads clearly, and
both note kinds can be filtered together via `search_query`.

Same resolution `/synapse-note` uses for a missing task ID (its "Resolving a missing task ID"),
reading the same file:

1. Infer the project from the current repo: check its project `CLAUDE.md` (title/"About" section) or
   `git remote`.
2. Check `~/.claude/synapse-projects.conf` (plain `project-name=prefix` lines, read/appended
   via Read/Edit, not the vault) for a loosely-matching project name. If found, use that prefix
   directly.
3. If not in the file yet, fall back to searching the vault for a prefix already in use for this
   project. If exactly one confidently matches, use it — and append the pair to the conf file.
4. If nothing confidently matches, ask the user for a short project tag — plain free-text, not a
   multiple-choice list, never hinting at any other project's tag as an example — then append the
   resolved pair to the conf file.

Never hardcode a specific project/prefix pair in this command's own instructions — the conf file is
machine-local and deliberately outside the portable Synapse package, so projects from
unrelated contexts (e.g. personal vs. work) never end up in the same place.

## Handling Arguments

**No arguments:**
1. Check for incomplete design notes: search `designs/` (via `mcp__obsidian__vault_list` +
   `vault_read`, or `search_query` scoped to the `designs/` path) for notes whose `## Status` line
   reads `Discussing`.
2. If found: show a short state summary — title and current section — and offer to resume.
3. If none: ask "What are we designing?"

**With a topic:**
1. Search first — `mcp__obsidian__search_simple` for the topic text across `designs/` (per the
   Synapse Vault rule: link/reuse over duplicate). Also check for an obvious title match.
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
4. None → "No incomplete design note found. Start one with `/synapse-design-note \"topic\"`."

**--list:**
1. `mcp__obsidian__vault_list` on `designs/`, then `vault_read` each (or a `search_query` scoped to
   that path) to pull title and `## Status`.
2. None found → "No design notes yet. Start one with `/synapse-design-note \"topic\"`."
3. Group into **Active** (`Discussing`, `Ready`) and **Closed** (`Reference`) — active first, title
   and status in backticks, not bold.

---

## Workflow

Free-form conversation, no fixed step order. Create the note on the first substantive answer and
update it after every meaningful exchange — don't wait until the end.

**Write it as settled understanding, not as a transcript of how it was reached.** Updating after
every exchange is about *when* to write, not license to narrate the conversation in the prose
itself. A section should read as if authored fresh today, stating the problem/approach/constraints
as they now stand — never as a log of what changed ("corrected during discussion," "reworked during
a live investigation," "the user pointed out," "originally X, now Y"). This applies strictly to
`## Problem`, `## Constraints`, and `## Open Questions` — always direct, current statements, no
exceptions.

`## Approach` is the one place a *trail* can be legitimate content — a rejected alternative and why
it failed is real, useful information for whoever reads this later, worth keeping even once the
working approach makes it moot. But phrase it as a fact about the solution space ("X fails because
Y, confirmed by Z"), never as commentary on the discussion that found it ("investigation showed,"
"the first attempt was"). Test: would the sentence still make sense to someone who wasn't in the
conversation and has no idea anything was ever revised? If not, rewrite it as a direct statement.

Angles worth covering (skip whatever's not relevant):
- What problem are we solving, and why now?
- What's the chosen approach? If there were real alternatives, a one-line "why not" for each.
- What are the hard constraints?
- Anything risky, or that needs deciding now vs. can be deferred?

### Concluding: Ready or Reference

- **Something to build** → `Status: Ready`. Confirm: "Design note ready: `designs/{title}.md`.
  Whenever you're ready to implement, generate the task with
  `/synapse-task-note \"{topic}\"` — no rush, nothing here expires."
- **Nothing to build** → `Status: Reference`. Confirm: "Design note concluded as Reference:
  `designs/{title}.md`. No task note needed."

If genuinely unsure which, ask the user directly.

There is no closing/renaming step here — nothing reads these notes automatically at session start,
so the `## Status` line is the only lifecycle marker that matters. It simply stays
`Ready`/`Reference` indefinitely.

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

No `Notes`/changelog section — it stays a small, single-conclusion note; there's no long-running
edit history here worth tracking separately.

## Filename

`designs/{PROJECT} — {Topic}.md` — sanitize filesystem-illegal characters (`/ : * ? " < > |`). No
slug, no numbering — Obsidian filenames are the title itself.

---

## Integration

- `/synapse-task-note "{topic}"` reads the matching `Ready` note as its only input.

---

## Example

```
User: /synapse-design-note "rollup direct storage"

Claude: [searches designs/ for existing matches — none found]

        What are we designing?

User: Replacing the AggregatingMergeTree rollup resolution with direct-value storage.

Claude: [creates designs/{PROJECT} — Rollup direct storage.md, Status: Discussing]

        What's driving this over just tuning the current argMaxMerge query?
...
User: The resolution cost alone dominates the query, tuning won't fix that. Mark it ready.

Claude: Design note ready: designs/{PROJECT} — Rollup direct storage.md.
        Generate the task with /synapse-task-note "rollup direct storage" whenever you're ready.
```
