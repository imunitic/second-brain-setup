Create a note in the Obsidian second-brain vault with the title and options, list existing notes, or search existing notes: $ARGUMENTS

## Argument parsing

If `$ARGUMENTS` is `--list` (or starts with `--list`) → **list mode**: see "List mode" below, skip note creation entirely.

If `$ARGUMENTS` starts with `--search` → **search mode**: see "Search mode" below, skip note creation entirely. This is also the mode to reach for programmatically (not just when the user explicitly asks to search) — per the second-brain CLAUDE.md instructions, linking to an existing note is the highest-priority step before creating a new one, so run a search here before every bare-mode note creation, not only when a search is requested outright.

Otherwise, split `$ARGUMENTS` on `--task`:

- If `--task` is present → **task mode**: scaffold the note as a tracked task, following the `obsidian-task` skill's conventions. Task notes always live under `projects/` (an `ecs-NNN` task belongs to the `eon` project).
- Otherwise → **bare mode**: create an empty node (title + frontmatter only). Which category folder it lands in (`projects` / `research` / `scratchpad`) is resolved in "Choosing a category (bare mode only)" below.

The title is everything before `--task` (trimmed). Example:

- `/obsidian-note "My idea"` → bare note titled "My idea"
- `/obsidian-note "ecs-035 — Implement Foo" --task` → task note titled "ecs-035 — Implement Foo"

In task mode, also attempt to extract a task ID from the title by matching the pattern `ecs-\d+`. Use it as `task_id` in frontmatter.

If no match is found, **don't just leave it blank** — see "Resolving a missing task ID" below before proceeding.

## List mode

Use `mcp__obsidian__search_query` with the JsonLogic query `{"var": "frontmatter.task_id"}` — this returns every file that has a `task_id` set, along with that file's `task_id` value as `result`. For each match, also read the file's `status` and `title` (either via a second query `{"var": "frontmatter.status"}` / `{"var": "frontmatter.title"}`, or via `mcp__obsidian__vault_read` on the handful of matched files — whichever is fewer round-trips for the count involved).

Categorize:
- **ecs notes**: `task_id` matches `ecs-\d+`. Split further into:
  - **Open**: `status` is `TODO`, `IN-PROGRESS`, or `REVIEW` (or missing — treat as open)
  - **Closed**: `status` is `DONE`, `CANCELED`, or `CANCELLED`
- **Other notes**: no `task_id`, or one that doesn't match `ecs-\d+`

Sort ecs notes numerically by task id (`ecs-9` before `ecs-10`); sort other notes alphabetically by title. Report as three sections — "ecs notes — open", "ecs notes — closed", "Other notes" — each line as `{task-id or filename} — {title} [{status}]`. Omit a section header if it has zero entries. End with a total count.

Do not modify any files in list mode.

## Search mode

Everything after `--search` (trimmed, quotes stripped) is the query.

1. Run `mcp__obsidian__search_simple` with the query — this gives full-text relevance-ranked matches with context, the closest equivalent to a title/body search.
2. If the query looks like it's targeting metadata specifically (a tag, a task ID, a status value) rather than free text, also run `mcp__obsidian__search_query` with an appropriate JsonLogic filter (e.g. `{"==": [{"var": "frontmatter.task_id"}, "ecs-032"]}`).
3. Report matches as `{title} — {file path relative to vault root}`, deduped across both. If nothing matches, say so plainly — the caller (agent or user) needs a clear "no existing note" signal to proceed with `--task`-less creation.

Do not modify any files in search mode.

## Resolving a missing task ID (task mode only)

Triggered when `--task` is given but the title doesn't match `ecs-\d+`.

1. Ask the user which project this task belongs to, via a question with
   known project/prefix pairs as options (currently just **eon → `ecs`**;
   add more here as new projects appear). Don't skip this question just
   because there's currently only one real choice — asking now is what
   makes it scale cleanly once a second project exists.

   The question tool requires **at least 2 explicit options**, even though
   it always separately offers a genuine free-text "Other" choice on top of
   whatever's listed. With only one real project, don't invent a fake
   second option that pretends to *be* the free-text path — that's
   confusing in practice. Instead make the second option an honest,
   clearly-non-free-text filler, e.g.:
   - "eon (ecs-*)" — the real project
   - "None of these" — description: "pick Other below instead, to type a
     new project's prefix directly"
2. Once the prefix is known, find the next number: run
   `mcp__obsidian__search_query` with `{"var": "frontmatter.task_id"}`,
   filter the returned `result` values client-side for ones matching
   `{prefix}-\d+`, take the highest number found, add 1. If none exist yet
   for that prefix, start at 1.
3. Format the new task ID **zero-padded to 3 digits** (`ecs-001`, `ecs-030`,
   `ecs-037`, ...), matching the org-roam-era convention — widening
   naturally past 3 digits if a prefix ever needs it.
4. **Prepend the resolved task ID to the title itself** — the final title
   becomes `{task-id} — {original title}` (em dash). Use this same final
   title for both the `title` frontmatter field and the `# ` heading, and
   use the resolved task ID for `task_id`. Don't let the frontmatter task
   ID and the visible title disagree.

## Choosing a category (bare mode only)

Task mode always uses `projects/` — skip this step entirely in task mode.

In bare mode, ask the user which category the note belongs to, via a
question with these options:

- **projects** — description: "tied to a specific coding project (e.g. eon)"
- **research** — description: "standalone research/reading notes, not tied to a project's dev log"
- **scratchpad** — description: "throwaway or in-progress, not yet worth filing"

Resolve this to a `category` (`"projects"`, `"research"`, or `"scratchpad"`)
before moving on to the creation steps below. Unlike `/roam-note`, no
project-slug question is needed here — Obsidian filenames are the title
itself, not a slug-prefixed timestamp, so there's no separate namespacing
concern to resolve.

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
  per the `obsidian-task` skill.
