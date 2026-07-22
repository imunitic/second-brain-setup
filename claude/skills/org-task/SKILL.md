---
name: org-task
description: Update org TODO entries with concise Notes summaries and enforce status transitions so active work is IN-PROGRESS and completed checklists move only to REVIEW (not DONE).
---

# Org TODO Summary + Status Skill

## When to invoke (proactive — do not wait to be asked)

Invoke this skill **automatically** in two situations:

1. **Starting work on an ecs-* task** — as soon as the user confirms work is beginning,
   before writing any code. Set the heading to `IN-PROGRESS` and update `:LAST_UPDATED:`.
   No notes needed at this point.

2. **Finishing work on an ecs-* task** — after all phases are committed and the task
   file checklist has been updated. Set the heading to `REVIEW` (if all items checked)
   or `IN-PROGRESS` (if any remain), update `:LAST_UPDATED:`, and append an
   implementation summary to the notes section.

Never wait for the user to explicitly call `/org-task` — apply it
proactively at both transitions.

## What this skill does

- Updates the task heading keyword (`TODO` → `IN-PROGRESS` or `REVIEW`).
- Updates `:LAST_UPDATED:` in the task `:PROPERTIES:` block.
- At task completion: appends concise implementation bullets to the existing notes
  section (or creates one if none exists).

## Status transitions

| Checklist state | Heading keyword |
|-----------------|----------------|
| Any `[ ]` unchecked | `IN-PROGRESS` |
| All `[X]` checked | `REVIEW` |

**Never set `DONE` through this workflow.** Do not manually write `DONE` into the
task heading either — always go through this skill, which caps at `REVIEW`.

## Procedure

1. Find the ecs-* org file: `rg --files ~/Roam | rg "ecs_NNN"` then read it.
2. Locate the target task heading (by `:TASK-ID:` property or heading title).
3. Inspect its checklist items (`[ ]` / `[X]`).
4. Determine heading keyword: `IN-PROGRESS` if any unchecked, `REVIEW` if all checked.
5. Update the heading keyword.
6. Fetch machine local time: `date '+%Y-%m-%d %H:%M'` — never use inferred time.
7. Update `:LAST_UPDATED:` in the `:PROPERTIES:` drawer.
8. **For completion only:** find the existing notes section (look for `* Notes` or
   `** Notes` at any heading level) and append implementation bullets. If no notes
   section exists, create `* Notes` at the top level of the file.

## Notes format

Append flat bullets to the existing notes section. Keep them factual and short:

- What was implemented / changed
- Key design decisions or deviations from the spec
- Files added or modified
- Validation result (`just check` / test counts)

Avoid creating a new heading if a notes section already exists at any level.
Append to the last existing notes section.

## Task file structure

Each ecs-* task file has **exactly one top-level TODO heading** (the task itself).
Implementation steps go as `- [ ]` checklist items **inside that heading**, not as
additional org headings. Do not create `** Step` or `*** Step` sub-headings for
implementation steps.

Correct structure:
```org
* TODO Implement something
  Description of the task.
  - [ ] Step one
  - [ ] Step two
  - [ ] Step three
```

Wrong structure (do not do this):
```org
* TODO Implement something
** TODO Step one
** TODO Step two
```

When adding steps to an existing task file, insert `- [ ]` items under the existing
TODO heading. Never add new top-level or sub-headings for implementation steps.

### Inline code examples in checklist items

Only applicable to code tasks. Non-code tasks (research, documentation,
configuration, simple one-liners) need no code blocks at all.

For code tasks, substantive checklist items (type definitions, API surfaces,
interface signatures) must include a `#+begin_src <lang>` block showing the
exact interface. Put the block directly under the checklist item text, indented
to match. Use the language appropriate to the project. Mechanical steps
(wiring, test registration, docs updates) do not need code blocks.

```org
  - [ ] Implement Foo

    One-line description of what this covers and any non-obvious constraints.

    #+begin_src <lang>
    // path/to/file
    interface or type definition goes here
    #+end_src
```

Draw the signatures directly from the design document. Do not paraphrase or
abbreviate — the checklist item is the implementor's authoritative reference.

### Notes section (pre-implementation)

Every new task file must have a `* Notes` section at the top level, **written
before implementation begins** (not only appended after completion). For tasks
backed by a design document, populate it with:

- Design reference: file path and task ID
- Key constraints the implementor must not miss
- Deliberate exclusions (what is out of scope and why)

For research or simple tasks with no design doc, a brief one-liner stating the
goal or context is sufficient. Omit the section only if there is genuinely
nothing non-obvious to capture.

```org
* Notes

  Design reference: docs/design/foo_design.md (task-NNN).

  - Key constraint one
  - Key constraint two
  - Out of scope: X (reason), Y (reason)
```

Post-implementation summaries are appended under `* Notes` as dated sub-headings
(`** YYYY-MM-DD — ...`), as shown in the completion procedure above.

## Creating a GitHub issue from a task

When the user asks to create a GitHub issue from a task file:

1. **Title** — `<TASK-ID> — <description>`, where `<TASK-ID>` is the `:TASK-ID:` property (e.g. `ecs-030`) and `<description>` is the heading stripped of its keyword (`TODO` / `IN-PROGRESS` / `REVIEW` / `DONE` / `CANCELED` / `CANCELLED`) **and any leading task-id prefix** (remove a leading `ecs-NNN`, `ecs-NNN —`, or `ecs-NNN - ` from the heading text). Example: heading `* DONE ecs-035 - Time resource implementation` → title `ecs-035 — Time resource implementation`.
2. **Body** — the full content of the top-level task heading: the description paragraph and all checklist items (with any inline code blocks), **converted from Org markup to GitHub-flavored Markdown via `pandoc`** (see below) — never pasted verbatim.
3. **First comment** — the full content of the `* Notes` section, same conversion applied, including any dated sub-headings and their bullets.
4. **State** — `gh issue create` has no `--state` flag; every issue is created open, then closed as a separate step if needed. Leave it open for `TODO`, `IN-PROGRESS`, and `REVIEW`. For `DONE`, close it after creating: `gh issue close <n>` (defaults to `state_reason: completed`). For `CANCELED`/`CANCELLED`, close it with `gh issue close <n> --reason "not planned"` — GitHub has no separate "canceled" issue state, `state_reason: not planned` is the closest real equivalent and distinguishes an abandoned task from a completed one in issue history/API queries.

### Org → GitHub-flavored Markdown conversion (via pandoc)

GitHub issues render GFM, not Org syntax — passing Org markup through unconverted leaves literal `=text=`, `#+begin_src`, and indented `**` sub-headings in the rendered issue instead of formatted code/headings/bold. **Use `pandoc -f org -t gfm`** for this — it has a real Org parser and is far more reliable than any regex-based substitution (an inline-code/bold-conversion regex will corrupt content that contains a bare `=`/`~`/`*` for unrelated reasons, e.g. `depth >= 0` or `*.mli`).

Procedure, per extracted fragment (the task-heading body, and separately the Notes section):

1. **Prepend `#+OPTIONS: ^:nil`** and a synthetic top-level heading (e.g. `* X`) before the fragment. Without `^:nil`, Org interprets bare underscores inside words (e.g. `collision_detection_functions.md`, `intersects_rect`) as subscript markup and pandoc emits broken `<sub>` HTML. The synthetic `* X` wrapper is needed so any `**`-prefixed lines in the fragment are recognized as real level-2 Org headings by the parser (see step 2) — strip the resulting `# X` line from the final output afterward.
2. **De-indent any `** heading` / `*** heading` lines to column 0** before running pandoc. Org only recognizes a heading if the `*` starts at the beginning of the line — task files sometimes indent these two spaces to visually nest them under a checklist item, which means Org (and pandoc) correctly treats them as **plain text**, not headings, if left indented. De-indenting first (a line-anchored regex is enough: `^[ \t]+(\*{2,}\s)` → `\1`) is a mechanical, purely-cosmetic fix — the indentation was never semantic.
3. **Insert spaces around any `/` that sits directly between two closing/opening markers** (`=a=/=b=` → `=a= / =b=`, and same for `~`). A bare `/` is not a valid Org emphasis boundary character, so `=a=/=b=` — a very common pattern in this codebase's prose (e.g. `=Tag=/=Meta=`) — fails to parse as two spans and pandoc mis-merges huge stretches of text looking for the next valid closer. Only fix the **marker-slash-marker** case this way; do *not* touch a lone marker's trailing slash (e.g. `=eon_engine/prefab/=` is one legitimate span whose *content* happens to end in `/` — inserting a space there breaks it). A regex like `=[ \t\n]*/[ \t\n]*=` → `= / =` (and the `~` equivalent) is safe because it requires markers on *both* sides.
4. **Run pandoc**: `pandoc -f org -t gfm --wrap=preserve <fragment>.org -o <fragment>.md`, then strip the leading `# X` line pandoc emitted for the synthetic wrapper heading.
5. **Manually spot-check for any remaining bare `=`/`~` next to letters** (`grep -nE '=[A-Za-z]|~[A-Za-z]'`, excluding fenced code blocks) — a small number of genuinely ambiguous cases can remain and need a one-off hand fix, not a more clever regex:
   - A span whose own *content* contains the marker character (e.g. Org source literally writing `=dist = radius=` to display an equality check, or `=dist_sq >= radius^2=` to display a comparison) is inherently ambiguous — Org's own nearest-closer-wins matching (faithfully reproduced by pandoc) will grab the *first* valid closer, which is often not the one the author intended. There's no generic fix; read the original line and hand-write the correct span split.
   - A single span immediately followed by a bare `/` and unmarked text (e.g. `=main.ml=/example` — note the `/example` half was never meant to be its own span) needs a one-off manual fix for the same underlying reason as step 3, just not the symmetric two-span case that regex covers.

Use `gh issue create` for the issue and `gh issue comment` for the Notes comment immediately after, passing the converted `.md` file content via `--body-file` (not inline `--body`, to avoid shell-quoting the Markdown). To edit an already-created issue/comment instead of creating a new one: `gh issue edit <n> --body-file <file>` for the issue body; comments have no `gh` subcommand for editing, use `gh api repos/<owner>/<repo>/issues/comments/<comment-id> -X PATCH -f body="$(cat <file>)"` (get the comment ID from the URL `gh issue comment` printed when it was created, or `gh api repos/<owner>/<repo>/issues/<n>/comments`).

```sh
gh issue create --title "..." --repo <owner>/<repo> --body-file body.md
gh issue comment <issue-number> --repo <owner>/<repo> --body-file notes.md
```

## Guardrails

- **Never write `DONE`** — not as a heading keyword, not manually, not through any
  other path. The cap is always `REVIEW`.
- Preserve org-roam properties untouched: `:ID:`, `:ROAM_ALIASES:`, `:ROAM_REFS:`,
  and any file-level `#+PROPERTY:` or `#+filetags:` lines. Never write to or
  remove `:ID:` — it is managed exclusively by org-roam.
- Use `:TASK-ID:` (e.g. `ecs-001`) as the human-readable task identifier; it is
  set manually and must not be auto-generated or overwritten.
- If checklist content is ambiguous or missing, default to `IN-PROGRESS`.
- Keep notes wording deterministic; avoid speculative claims.
