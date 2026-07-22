---
name: obsidian-task
description: Update Obsidian task notes' status frontmatter and Notes sections, enforcing status transitions so active work is IN-PROGRESS and completed checklists move only to REVIEW (not DONE).
---

# Obsidian Task Status Skill

Markdown/Obsidian counterpart to `org-task`, for task notes tracked in the
Obsidian second-brain vault instead of org-roam. Same state machine, same
guardrails — the only real difference is the storage format: a `status:`
frontmatter field instead of an org heading keyword, and GFM `- [ ]`/`- [x]`
checklists (already the native format here, no conversion needed).

## When to invoke (proactive — do not wait to be asked)

Invoke this skill **automatically** in two situations:

1. **Starting work on an ecs-* task** — as soon as the user confirms work is
   beginning, before writing any code. Set `status: IN-PROGRESS` and update
   `last_updated`. No notes needed at this point.

2. **Finishing work on an ecs-* task** — after all phases are committed and
   the task note's checklist has been updated. Set `status: REVIEW` (if all
   items checked) or `status: IN-PROGRESS` (if any remain), update
   `last_updated`, and append an implementation summary to the `## Notes`
   section.

Never wait for the user to explicitly call `/obsidian-task` — apply it
proactively at both transitions.

## What this skill does

- Updates the `status:` frontmatter field (`TODO` → `IN-PROGRESS` or
  `REVIEW`).
- Updates `last_updated` in frontmatter.
- At task completion: appends concise implementation bullets to the
  existing `## Notes` section (or creates one if none exists).

## Status transitions

| Checklist state | `status:` value |
|-----------------|-----------------|
| Any `[ ]` unchecked | `IN-PROGRESS` |
| All `[x]` checked | `REVIEW` |

**Never set `DONE` through this workflow.** Do not manually write `DONE`
into `status:` either — always go through this skill, which caps at
`REVIEW`.

## Procedure

1. Find the task note: `mcp__obsidian__search_query` with
   `{"==": [{"var": "frontmatter.task_id"}, "ecs-NNN"]}`, then
   `mcp__obsidian__vault_read` the matched file.
2. Inspect its checklist items (`- [ ]` / `- [x]`).
3. Determine the new `status:` value: `IN-PROGRESS` if any unchecked,
   `REVIEW` if all checked.
4. Fetch machine local time: `date '+%Y-%m-%d %H:%M'` — never use inferred
   time.
5. Update `status:` and `last_updated:` in frontmatter with
   `mcp__obsidian__vault_patch` (`targetType: frontmatter`, `operation:
   replace`) — one call per field, confirmed safe (only touches that key).
6. **For completion only:** append implementation bullets to the existing
   `## Notes` section with `mcp__obsidian__vault_patch`
   (`targetType: heading`, `target: "{H1 title}::Notes"`, `operation:
   append`) — append is safe here too. **The target must be the full
   nested path** (`H1::Notes`), not just `"Notes"` — verified by testing:
   since `## Notes` is nested under the top-level `# {title}` heading, the
   plugin's heading lookup fails with "target not found in document" on
   the bare leaf name and requires the `::`-joined path from the tool's
   own docs. If no notes section exists, same call with
   `createTargetIfMissing: true`.

**Do not use `vault_patch` with `operation: replace` on the top-level
heading to edit checklist items.** Verified by testing: "content beneath
heading" for a top-level (`#`) heading extends through *all* nested
subheadings (including `## Notes`), not just the leading paragraph/checklist
directly under it — a replace there silently deletes everything past the
checklist, including the Notes section. To check off checklist items,
instead `vault_read` the full file, edit the `- [ ]` → `- [x]` lines in the
returned content, and `vault_write` the whole file back.

## Notes format

Append flat bullets to the existing notes section. Keep them factual and short:

- What was implemented / changed
- Key design decisions or deviations from the spec
- Files added or modified
- Validation result (`just check` / test counts)

Avoid creating a new heading if a notes section already exists at any
level. Append to the last existing notes section.

## Task file structure

Each ecs-* task note has **exactly one top-level heading** (the task
itself, `# {title}`). Implementation steps go as `- [ ]` checklist items
**under that heading**, not as additional headings. Do not create `##
Step` sub-headings for implementation steps.

Correct structure:
```md
# Implement something

Description of the task.
- [ ] Step one
- [ ] Step two
- [ ] Step three
```

Wrong structure (do not do this):
```md
# Implement something
## Step one
## Step two
```

### Inline code examples in checklist items

Only applicable to code tasks. Non-code tasks (research, documentation,
configuration, simple one-liners) need no code blocks at all.

For code tasks, substantive checklist items (type definitions, API
surfaces, interface signatures) must include a fenced code block showing
the exact interface, directly under the checklist item text, indented to
match:

```md
- [ ] Implement Foo

  One-line description of what this covers and any non-obvious constraints.

  ```ocaml
  // path/to/file
  interface or type definition goes here
  ```
```

Draw the signatures directly from the design document. Do not paraphrase
or abbreviate — the checklist item is the implementor's authoritative
reference.

### Notes section (pre-implementation)

Every new task note must have a `## Notes` section, **written before
implementation begins** (not only appended after completion). For tasks
backed by a design document, populate it with:

- Design reference: file path and task ID
- Key constraints the implementor must not miss
- Deliberate exclusions (what is out of scope and why)

For research or simple tasks with no design doc, a brief one-liner stating
the goal or context is sufficient. Omit the section only if there is
genuinely nothing non-obvious to capture.

```md
## Notes

Design reference: docs/design/foo_design.md (task-NNN).

- Key constraint one
- Key constraint two
- Out of scope: X (reason), Y (reason)
```

Post-implementation summaries are appended under `## Notes` as dated
sub-headings (`### YYYY-MM-DD — ...`), as shown in the completion
procedure above.

## Creating a GitHub issue from a task

When the user asks to create a GitHub issue from a task note:

1. **Title** — `<TASK-ID> — <description>`, where `<TASK-ID>` is the
   `task_id` frontmatter field (e.g. `ecs-030`) and `<description>` is the
   heading with any leading task-id prefix stripped (`ecs-NNN`, `ecs-NNN —`,
   or `ecs-NNN - `). Example: heading `# ecs-035 - Time resource
   implementation` → title `ecs-035 — Time resource implementation`.
2. **Body** — the full content of the top-level heading section: the
   description paragraph and all checklist items (with any inline code
   blocks). **No conversion step needed** — the note is already GFM
   Markdown, unlike org-task's org→GFM pandoc pipeline, so this goes
   straight into `gh issue create --body-file` unchanged.
3. **First comment** — the full content of the `## Notes` section,
   including any dated sub-headings and their bullets, straight into
   `gh issue comment --body-file` unchanged.
4. **State** — `gh issue create` has no `--state` flag; every issue is
   created open, then closed as a separate step if needed. Leave it open
   for `TODO`, `IN-PROGRESS`, and `REVIEW`. For `DONE`, close it after
   creating: `gh issue close <n>` (defaults to `state_reason: completed`).
   For `CANCELED`/`CANCELLED`, close it with `gh issue close <n> --reason
   "not planned"`.

```sh
gh issue create --title "..." --repo <owner>/<repo> --body-file body.md
gh issue comment <issue-number> --repo <owner>/<repo> --body-file notes.md
```

To edit an already-created issue/comment instead of creating a new one:
`gh issue edit <n> --body-file <file>` for the issue body; comments have no
`gh` subcommand for editing, use `gh api
repos/<owner>/<repo>/issues/comments/<comment-id> -X PATCH -f
body="$(cat <file>)"` (get the comment ID from the URL `gh issue comment`
printed when it was created, or `gh api
repos/<owner>/<repo>/issues/<n>/comments`).

## Guardrails

- **Never write `DONE`** — not in `status:`, not manually, not through any
  other path. The cap is always `REVIEW`.
- Preserve `task_id` untouched — it is set manually (or resolved once by
  `/obsidian-note --task`) and must not be auto-generated or overwritten.
- If checklist content is ambiguous or missing, default to `IN-PROGRESS`.
- Keep notes wording deterministic; avoid speculative claims.
