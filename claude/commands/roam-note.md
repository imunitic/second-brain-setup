---
description: Create an org-roam node via emacsclient and open it in the running Emacs daemon, list all notes with --list, or search existing notes with --search.
argument-hint: '"title" [--task] | --list | --search "query"'
---

Create an org-roam node with the title and options, list existing notes, or search existing notes: $ARGUMENTS

## Argument parsing

If `$ARGUMENTS` is `--list` (or starts with `--list`) → **list mode**: see "List mode" below, skip note creation entirely.

If `$ARGUMENTS` starts with `--search` → **search mode**: see "Search mode" below, skip note creation entirely. This is also the mode to reach for programmatically (not just when the user explicitly asks to search) — per the org-roam CLAUDE.md instructions, linking to an existing note is the highest-priority step before creating a new one, so run a search here before every bare-mode note creation, not only when a search is requested outright.

Otherwise, split `$ARGUMENTS` on `--task`:

- If `--task` is present → **task mode**: scaffold the note as an org TODO entry following the `org-task` skill conventions. Task notes always live under `projects/` (an `ecs-NNN` task belongs to the `eon` project).
- Otherwise → **bare mode**: create an empty node (title + ID only). Which category folder it lands in (`projects` / `research` / `scratchpad`) is resolved in "Choosing a category (bare mode only)" below.

The title is everything before `--task` (trimmed). Example:

- `/roam-note "My idea"` → bare note titled "My idea"
- `/roam-note "ecs-035 — Implement Foo" --task` → task note titled "ecs-035 — Implement Foo"

In task mode, also attempt to extract a task ID from the title by matching the pattern `ecs-\d+`. Use it as `:TASK-ID:` in the properties drawer.

If no match is found, **don't just leave it blank** — see "Resolving a missing task ID" below before proceeding.

## List mode

No Emacs daemon required — this reads files directly, it doesn't need to open anything.

1. Find the roam directory: `~/Roam`. If it doesn't exist, search `find ~ -maxdepth 3 -iname "Roam" -type d 2>/dev/null` before giving up.
2. For every `*.org` file in that directory (skip `org-roam.db` and any non-`.org` files), extract:
   - `#+title:` line
   - `:TASK-ID:` property value (blank/absent if none)
   - the TODO keyword on the first `* KEYWORD ...` heading (`TODO`, `IN-PROGRESS`, `REVIEW`, `DONE`, `CANCELED`/`CANCELLED`, or none)

   Example extraction per file:
   ```bash
   rg -m1 "^#\+title:" "$f"
   rg -m1 "^:TASK-ID:" "$f"
   rg -m1 "^\* (TODO|IN-PROGRESS|REVIEW|DONE|CANCELED|CANCELLED)" "$f"
   ```
3. Categorize each file:
   - **ecs notes**: `:TASK-ID:` matches `ecs-\d+` (trim whitespace before matching — some files have extra spaces after the colon). Split further into:
     - **Open**: heading keyword is `TODO`, `IN-PROGRESS`, or `REVIEW` (or missing/no heading — treat as open, not closed)
     - **Closed**: heading keyword is `DONE`, `CANCELED`, or `CANCELLED`
   - **Other notes**: no `:TASK-ID:` property, or one that doesn't match `ecs-\d+`
4. Sort ecs notes numerically by task id (`ecs-9` before `ecs-10`); sort other notes alphabetically by title.
5. Report as three sections — "ecs notes — open", "ecs notes — closed", "Other notes" — each line as `{task-id or filename} — {title} [{status}]`. Show the actual keyword (e.g. `[CANCELED]`, `[DONE]`) in the status tag, not just open/closed. Omit a section header if it has zero entries. End with a total count.

Do not modify any files in list mode.

## Search mode

Everything after `--search` (trimmed, quotes stripped) is the query. No
Emacs daemon required for the query itself — this reads `org-roam.db`
directly via `sqlite3`, per the "Searching notes" section of the global
CLAUDE.md.

1. Find the db: `~/Roam/org-roam.db` (or `$ORG_ROAM_DIR/org-roam.db` if
   that env var is set). If missing, search `find ~ -maxdepth 3 -iname
   "org-roam.db" 2>/dev/null` before giving up.
2. Run a title search and a tag search against the query, both
   case-insensitive substring matches:
   ```bash
   sqlite3 ~/Roam/org-roam.db "select title, file from nodes where title like '%${query}%' collate nocase;"
   sqlite3 ~/Roam/org-roam.db "select nodes.title, nodes.file from tags join nodes on tags.node_id = nodes.id where tags.tag like '%${query}%' collate nocase;"
   ```
   Quote `$query` carefully — build the SQL with a parameter-safe method
   (e.g. printf into a variable, not raw string interpolation of
   unsanitized user/agent input) since this runs as a literal shell
   command.
3. If Emacs is reachable, `emacsclient --eval '(org-roam-db-query ...)'`
   is an equally valid substitute per CLAUDE.md, but sqlite3 alone is
   sufficient and doesn't require the daemon.
4. Report matches as `{title} — {file path relative to ~/Roam}`, deduped
   across the title/tag queries. If nothing matches, say so plainly — the
   caller (agent or user) needs a clear "no existing note" signal to
   proceed with `--task`-less creation.

Do not modify any files in search mode.

## Resolving a missing task ID (task mode only)

Triggered when `--task` is given but the title doesn't match `ecs-\d+`. Pure
file scanning — no Emacs daemon needed for this part, do it before Step 1.

1. Ask the user which project this task belongs to, via a question with
   known project/prefix pairs as options (currently just **eon → `ecs`**;
   add more here as new projects appear). Don't skip this question just
   because there's currently only one real choice — asking now is what
   makes it scale cleanly once a second project exists.

   The question tool requires **at least 2 explicit options**, even though
   it always separately offers a genuine free-text "Other" choice on top of
   whatever's listed. With only one real project, don't invent a fake
   second option that pretends to *be* the free-text path (e.g. "type a
   custom prefix" or "something else") — that's confusing in practice, it
   reads as a real button but produces nothing useful when clicked. Instead
   make the second option an honest, clearly-non-free-text filler, e.g.:
   - "eon (ecs-*)" — the real project
   - "None of these" — description: "pick Other below instead, to type a
     new project's prefix directly"

   The actual custom-prefix entry only ever happens via the tool's own
   automatic "Other" chip, never via anything in the explicit options list.
2. Once the prefix is known, find the next number: scan `~/Roam/*.org` for
   `:TASK-ID:` values matching `{prefix}-\d+`, e.g.:
   ```bash
   rg -oN ":TASK-ID:\s*${prefix}-([0-9]+)" -r '$1' ~/Roam/*.org | sort -n | tail -1
   ```
   Take the highest number found, add 1. If none exist yet for that prefix,
   start at 1.
3. Format the new task ID **zero-padded to 3 digits** (`printf "%s-%03d" "$prefix" "$next"`),
   matching the existing convention (`ecs-001`, `ecs-030`, `ecs-037`, ...) —
   widening naturally past 3 digits if a prefix ever needs it.
4. **Prepend the resolved task ID to the title itself** — the final title
   becomes `{task-id} — {original title}` (em dash, matching every existing
   note). Use this same final title for both `#+title:` and the `* TODO`
   heading, and use the resolved task ID for `:TASK-ID:`. Don't let the
   properties-drawer task ID and the visible title disagree — that
   inconsistency is exactly what breaks the `org-task` skill's "copy title
   verbatim into the GitHub issue" step later.

## Choosing a category (bare mode only)

Notes are organized into `projects/`, `research/`, `scratchpad/` under
`org-roam-directory` (see `~/Roam/index.org` for what each is for). Task
mode always uses `projects/` — skip this step entirely in task mode.

In bare mode, ask the user which category the note belongs to, via a
question with these options:

- **projects** — description: "tied to a specific coding project (e.g. eon)"
- **research** — description: "standalone research/reading notes, not tied to a project's dev log"
- **scratchpad** — description: "throwaway or in-progress, not yet worth filing"

If **projects** is chosen, also ask for the project slug (currently just
`eon`; offer it as one option plus an honest non-free-text filler like
"None of these — pick Other below", same pattern as the org-task skill's
"Resolving a missing task ID" question — the real custom-prefix entry only
ever happens via the tool's own automatic "Other" chip).

Resolve this to a `category` (`"projects"`, `"research"`, or `"scratchpad"`)
and, only when `category` is `"projects"`, a `project-slug`, before moving
on to Steps 1-4.

## Steps

### 1. Locate the socket

```bash
SOCK=~/.emacs.d/var/server/server
```

If that path doesn't exist, search before giving up:

```bash
find ~/.emacs.d -maxdepth 4 -iname "server" 2>/dev/null
```

macOS default `/tmp/emacs$(id -u)/server` as a last resort.

### 2. Test connectivity

```bash
emacsclient --socket-name="$SOCK" --eval '(emacs-version)'
```

If this errors → stop and report: "Emacs daemon isn't reachable at `{socket path}` — is it running? (`M-x server-start` or `emacs --daemon`)." Do not retry or fall back to writing a plain file.

### 3. Create and register the node

Run this single `--eval` call. Choose the file content based on mode:

**Bare mode** — file content:

```
:PROPERTIES:
:ID:       {id}
:END:
#+title: {title}

```

**Task mode** — file content (following org-task conventions):

```
:PROPERTIES:
:ID:       {id}
:TASK-ID:  {task-id-or-blank}
:LAST_UPDATED: {YYYY-MM-DD HH:MM}
:END:
#+title: {title}

* TODO {title}

* Notes

```

Filename lands under the resolved category subfolder (`projects`,
`research`, or `scratchpad` — `projects` always in task mode, otherwise
whatever was resolved in "Choosing a category" above). In `projects`, the
filename gets `{project-slug}_` prepended ahead of the title slug, matching
`_tool-roam-local.el`'s `"p"` capture template exactly
(`TIMESTAMP-{project_slug}_{slug}.org`); for task mode this project slug
prefix is normally redundant with the title (which already starts with the
task ID, e.g. `ecs-037 - ...`, so its slug is already `ecs_037_...`) — only
add it if the title doesn't already start with a recognized task-id prefix.
In `research`/`scratchpad`, filename is unchanged (`TIMESTAMP-{slug}.org`).

Use this elisp template, substituting content for the appropriate mode:

```elisp
(progn
  (require 'org-roam)
  (let* ((title "{title}")
         (id (org-id-new))
         (category "{category}")           ; "projects" | "research" | "scratchpad"
         (dir (expand-file-name category org-roam-directory))
         (slug (replace-regexp-in-string "_+" "_"
                 (replace-regexp-in-string "[^a-z0-9]+" "_" (downcase title))))
         (basename (if (and (string= category "projects")
                             (not (string-match-p "\\`ecs_[0-9]+_" slug)))
                       (concat "{project-slug}_" slug)
                     slug))
         (filename (expand-file-name
                     (format "%s-%s.org" (format-time-string "%Y%m%d%H%M%S") basename)
                     dir))
         (now (format-time-string "%Y-%m-%d %H:%M")))
    (unless (file-directory-p dir) (make-directory dir t))
    (with-temp-buffer
      (insert {file-content-string})
      (write-file filename))
    (org-roam-db-update-file filename)
    (let* ((buf (find-file-noselect filename))
           (gui-frame (car (or (seq-filter #'display-graphic-p (frame-list))
                                (frame-list)))))
      (with-selected-frame gui-frame
        (pop-to-buffer buf))
      (select-frame-set-input-focus gui-frame))
    filename))
```

Use `format` to build the content string, substituting `id`, `title`, `now`, and `task-id` as appropriate.

### 4. Confirm

Report the file path and the org-id to the user.

- Bare mode: note that the node is intentionally empty.
- Task mode: note the task ID extracted (or that `:TASK-ID:` was left blank for manual entry), and remind the user to populate the `* Notes` section and checklist before starting work, per the `org-task` skill.

## Failure handling

- No socket found → "Emacs daemon doesn't appear to be running." Stop.
- Socket found but `--eval` errors → surface the actual error message verbatim.
- `org-roam-directory` unset or inaccessible → surface the raw error.
