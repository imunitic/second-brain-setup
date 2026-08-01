Create a note in the Obsidian second-brain vault with the title and options, list existing notes, or search existing notes: $ARGUMENTS

## Argument parsing

If `$ARGUMENTS` is `--list` (or starts with `--list`) → **list mode**: see "List mode" below, skip note creation entirely.

If `$ARGUMENTS` starts with `--search` → **search mode**: see "Search mode" below, skip note creation entirely. This is also the mode to reach for programmatically (not just when the user explicitly asks to search) — per the second-brain CLAUDE.md instructions, linking to an existing note is the highest-priority step before creating a new one, so run a search here before every bare-mode note creation, not only when a search is requested outright.

Otherwise, split `$ARGUMENTS` on `--task`:

- If `--task` is present → **task mode**: scaffold the note as a tracked task, following the `sb-task` skill's conventions. Task notes always live under `projects/`.
- Otherwise → **bare mode**: create an empty node (title + frontmatter only). Which category folder it lands in (`projects` / `research` / `scratchpad`) is resolved in "Choosing a category (bare mode only)" below.

The title is everything before `--task` (trimmed). Example:

- `/sb-note "My idea"` → bare note titled "My idea"
- `/sb-note "proj-035 — Implement Foo" --task` → task note titled "proj-035 — Implement Foo"

In task mode, also attempt to extract a task ID from the title by matching a `{prefix}-\d+` pattern (letters, a hyphen, then digits). Use it as `task_id` in frontmatter.

If no match is found, **don't just leave it blank** — see "Resolving a missing task ID" below before proceeding.

## List mode

Use `mcp__obsidian__search_query` with the JsonLogic query `{"var": "frontmatter.task_id"}` — this returns every file that has a `task_id` set, along with that file's `task_id` value as `result`. For each match, also read the file's `status` and `title` (either via a second query `{"var": "frontmatter.status"}` / `{"var": "frontmatter.title"}`, or via `mcp__obsidian__vault_read` on the handful of matched files — whichever is fewer round-trips for the count involved).

Categorize:
- **Prefixed notes**: `task_id` matches `{prefix}-\d+`. Group by the distinct prefix found (whatever
  prefixes actually appear — don't assume a fixed set). Within each prefix, split further into:
  - **Open**: `status` is `TODO`, `IN-PROGRESS`, or `REVIEW` (or missing — treat as open)
  - **Closed**: `status` is `DONE`, `CANCELED`, or `CANCELLED`
- **Other notes**: no `task_id`, or one that doesn't match `{prefix}-\d+`

Sort each prefix group's notes numerically by task id (`{prefix}-9` before `{prefix}-10`); sort other notes alphabetically by title. Report one section per prefix found — "{prefix} notes — open", "{prefix} notes — closed" — plus "Other notes", each line as `{task-id or filename} — {title} [{status}]`. Omit a section header if it has zero entries. End with a total count.

Do not modify any files in list mode.

## Search mode

Everything after `--search` (trimmed, quotes stripped) is the query.

1. Run `mcp__obsidian__search_simple` with the query — this gives full-text relevance-ranked matches with context, the closest equivalent to a title/body search.
2. If the query looks like it's targeting metadata specifically (a tag, a task ID, a status value) rather than free text, also run `mcp__obsidian__search_query` with an appropriate JsonLogic filter (e.g. `{"==": [{"var": "frontmatter.task_id"}, "proj-032"]}`).
3. Report matches as `{title} — {file path relative to vault root}`, deduped across both. If nothing matches, say so plainly — the caller (agent or user) needs a clear "no existing note" signal to proceed with `--task`-less creation.

Do not modify any files in search mode.

## Resolving a missing task ID (task mode only)

Triggered when `--task` is given but the title doesn't match `{prefix}-\d+`.

The known project/prefix pairs live in a plain local file, `~/.claude/second-brain-projects.conf`
(one `project-name=prefix` line each) — read/appended with the Read/Edit tools, not the `obsidian`
MCP server, since it's outside the vault. It is deliberately **not** part of the portable
second-brain-setup package and never copied between machines, so contexts that shouldn't mix (e.g.
personal vs. work projects) never end up in the same file. It's self-managed — this command appends
newly resolved pairs to it — but also plain text, so the user can add, fix, or remove a line by hand
at any time.

1. Identify the current project from context: the repo's `CLAUDE.md` (title/"About" section) or
   `git remote`.
2. Check `~/.claude/second-brain-projects.conf` for a line whose project name matches (loosely —
   case/whitespace-insensitive). If found, use that prefix directly — no need to ask.
3. If the file doesn't have it yet, fall back to deducing from the vault itself (useful the first
   time this runs, or for a project whose notes predate this file): `search_simple` for the
   project/repo name across existing notes, and/or `search_query` on
   `{"var": "frontmatter.task_id"}` to see which prefixes exist, then check whether any of those
   prefixed notes reference this project. If exactly one prefix confidently matches, use it.
4. If nothing confidently matches (new project, or an ambiguous/multiple match), ask the user
   directly: "What's the project prefix for this task?" — plain free-text, not a multiple-choice
   list. Don't offer or hint at any other project's prefix as an option.
5. Whenever step 3 or step 4 resolves a pair not already in the conf file (including a fresh
   `project-name=prefix` line matching what was just deduced or asked), append it — so the next task
   for this project resolves from step 2 without a search or a question.
6. Once the prefix is known, find the next number: run
   `mcp__obsidian__search_query` with `{"var": "frontmatter.task_id"}`,
   filter the returned `result` values client-side for ones matching
   `{prefix}-\d+`, take the highest number found, add 1. If none exist yet
   for that prefix, start at 1.
7. Format the new task ID **zero-padded to 3 digits** (`{prefix}-001`, `{prefix}-030`,
   `{prefix}-037`, ...), matching the org-roam-era convention — widening
   naturally past 3 digits if a prefix ever needs it.
8. **Prepend the resolved task ID to the title itself** — the final title
   becomes `{task-id} — {original title}` (em dash). Use this same final
   title for both the `title` frontmatter field and the `# ` heading, and
   use the resolved task ID for `task_id`. Don't let the frontmatter task
   ID and the visible title disagree.

`/sb-design-note`/`/sb-task-note` read the same conf file directly for the same reason —
they don't duplicate this resolution logic, just this file.

## Choosing a category (bare mode only)

Task mode always uses `projects/` — skip this step entirely in task mode.

In bare mode, ask the user which category the note belongs to, via a
question with these options:

- **projects** — description: "tied to a specific coding project"
- **research** — description: "standalone research/reading notes, not tied to a project's dev log"
- **scratchpad** — description: "throwaway or in-progress, not yet worth filing"

Resolve this to a `category` (`"projects"`, `"research"`, or `"scratchpad"`)
before moving on to the creation steps below. No project-slug question is
needed here — Obsidian filenames are the title itself, not a
slug-prefixed timestamp, so there's no separate namespacing concern to
resolve.

## Creating the note

1. Sanitize the title into a filename: replace filesystem-illegal
   characters (`/ : * ? " < > |`) with `-`, collapse repeated whitespace.
   No timestamp prefix, no project-slug prefix — the filename is just the
   (sanitized) title.
2. Fetch machine local time: `date '+%Y-%m-%d %H:%M'` — never use inferred
   time. Use this for the `created` frontmatter field.
3. Build the file content:

   **Bare mode:**
   ```
   ---
   title: "{title}"
   created: "{now}"
   ---

   ```

   **Task mode:**
   ```
   ---
   title: "{title}"
   created: "{now}"
   task_id: {task-id}
   status: TODO
   last_updated: "{now}"
   ---

   # {title}

   ## Notes

   ```
4. Write it with `mcp__obsidian__vault_write`, path
   `{category}/{filename}.md` (category resolved above; always `projects`
   in task mode).

## Confirm

Report the file path back to the user.

- Bare mode: note that the note is intentionally near-empty.
- Task mode: note the task ID extracted or resolved, and remind the user
  to populate the `## Notes` section and checklist before starting work,
  per the `sb-task` skill.
