# Second brain as permanent memory

The user keeps a permanent, curated knowledge base — their "second brain" —
as a memory system separate from and complementary to the `~/.claude`
auto-memory system: use the second brain for durable, browsable
knowledge-base notes, not for session bookkeeping. The backend storing it
is swappable and may change over time. Check `~/.claude/second-brain.conf`
(`BACKEND=obsidian` or `BACKEND=org-roam`, plus the paths for each) if
you're ever unsure which is active — but a SessionStart hook already
injects the active backend's index note at the start of every session, so
this should rarely be necessary. Don't re-read the index reflexively, but
do treat its injected contents as live information, not background flavor.

**This is a primary, load-bearing memory system, not an optional nicety.**
Actively use it — don't wait to be asked. You MUST create or update a note
(no permission needed first, as long as it lands in the right folder per
the index) whenever, during a session, any of the following happens:

- A non-trivial bug is diagnosed and fixed, especially if the root cause
  or the fix was non-obvious.
- The user states a preference, a decision, or a piece of standing
  context ("we always do X", "the reason we do Y is...") that isn't
  already captured in a note.
- A project reaches a milestone, or its direction/scope changes.
- You do research (reading docs, comparing libraries/approaches,
  evaluating tradeoffs) that would be wasteful to redo from scratch next
  time.
- An existing note is now stale or wrong in light of what just happened —
  update it in place rather than leaving it to rot.

If none of these clearly apply, err on the side of asking yourself the
question rather than silently skipping it — a nudge hook periodically
prompts exactly this check; treat that prompt as a real question requiring
a real yes/no answer, not a formality to wave past.

- **Linking is the highest-priority step, not an afterthought.** Before
  writing a new note, search for related existing notes (see the
  backend-specific "Searching notes" instructions below) and link to
  them — prefer linking over duplicating content every time a related
  note exists. If genuinely nothing else applies, link the new note back
  to the index itself rather than leaving it an orphan with zero
  backlinks.
- **Split growing notes rather than letting one balloon.** During a long
  session (e.g. a multi-hour debugging or optimization effort), don't just
  keep appending every new finding to the same note indefinitely. Once a
  note is accumulating genuinely separate findings/topics rather than one
  cohesive update, split the new material into its own linked note instead
  of growing the original further. A handful of focused, well-linked notes
  is more useful later than one sprawling one — easier to search, easier to
  link into from elsewhere, easier to skim.
- Folders are the same across backends: `projects/` (dev-log notes tied to
  a specific coding project), `research/` (standalone research/reading
  notes), `scratchpad/` (throwaway/in-progress notes), `inbox/` (doesn't
  cleanly fit the others). Agents may create new folders beyond these, but
  folder depth is capped at two levels (`folder/subfolder`, never deeper).
  Creating a new top-level folder requires adding a matching entry to the
  active backend's index note in the same action — the index must never
  fall behind what's actually on disk. If nothing about a note fits an
  existing or obviously-new category, put it in `inbox/` rather than
  forcing a bad fit or inventing a folder for a one-off.

## Backend: obsidian (current default)

Vault at `$OBSIDIAN_VAULT_DIR` (see `~/.claude/second-brain.conf`), index
note `Index.md` at the vault root. Reachable both as plain files on disk
and live through the `obsidian` MCP server (user-scoped, so available from
any project) backed by the Local REST API plugin.

- You may create and edit notes in this vault **without asking for
  permission first**, as long as each note is placed in the folder
  matching its category per `Index.md`.
- Filenames are human-readable titles (not timestamp-prefixed — Obsidian's
  sidebar/graph display the filename directly, so a timestamp prefix reads
  poorly there, unlike org-roam). Sanitize filesystem-illegal characters
  (`/ : * ? " < > |`) but otherwise keep the title as-is.
- Frontmatter carries what the filename no longer does: `title`, `created`
  (real timestamp at creation time), and for task notes `task_id` /
  `status` (`TODO`/`IN-PROGRESS`/`REVIEW`/`DONE`/`CANCELED`).
- Link with Obsidian wikilinks: `[[filename]]` or `[[filename|display
  text]]` (no extension, exact filename minus `.md`).
- Create notes via the `/obsidian-note` command; task-tracking notes are
  additionally managed by the `obsidian-task` skill (proactive status
  transitions, mirroring `org-task` but via the `status:` frontmatter
  field instead of org heading keywords).

### Searching notes (obsidian)

Prefer the `mcp__obsidian__` MCP tools over raw file grepping — they're
live against the running vault and don't require re-deriving paths:

- `mcp__obsidian__search_simple` — full-text search with relevance scoring
  and match context, for "does a note about X already exist" checks.
- `mcp__obsidian__search_query` — JsonLogic queries over note metadata
  (frontmatter fields, tags, links, backlinks, path globs) when you need a
  structured filter rather than free text, e.g. finding all notes with a
  given `task_id` or `status`.
- `mcp__obsidian__vault_list` / `vault_read` for direct navigation when you
  already know roughly where something is.

## Backend: org-roam (fallback)

Knowledge base at `$ORG_ROAM_DIR` (fall back to `~/Roam` if unset). Index
note at `~/Roam/index.org`.

- You may create and edit org-roam notes in this store **without asking
  for permission first**, as long as each note is placed in the folder
  matching its category per the index.
- Filenames follow `TIMESTAMP-slug.org` (or `TIMESTAMP-{project_slug}_slug.org`
  under `projects/`); each note gets a real org-id `:ID:` property so it can
  be linked with `[[id:...][description]]`.
- Create notes via the `/roam-note` command; task-tracking notes are
  additionally managed by the `org-task` skill.

### Searching notes (org-roam)

**Always prefer querying `org-roam.db`** (a SQLite file at
`~/Roam/org-roam.db`) over grepping the whole notes folder before you
write anything new — it indexes titles, tags, and links, and is far
cheaper than a full-text scan across every file. Checking for an existing
or related note is not optional busywork; do it first, every time, so
linking (above) actually has something to link to:

```
sqlite3 ~/Roam/org-roam.db "select title, file from nodes where title like '%foo%';"
sqlite3 ~/Roam/org-roam.db "select source, dest from links where type = 'id';"
```

If Emacs is reachable (check `~/.emacs.d` conventions — it typically runs as
a daemon with a custom socket), `emacsclient --eval '(org-roam-db-query ...)'`
works too and stays in sync automatically. Fall back to `rg`/grep over the
notes folder only for full-text body search, since note bodies aren't
indexed in the db.

## Switching backends

`~/.claude/second-brain.conf` is the single source of truth for which
backend is active. Switch with `~/.claude/bin/second-brain-switch
<org-roam|obsidian>` — it takes effect immediately (hooks are fresh
processes that re-read the config each time; no restart needed for hooks,
though an already-running session's own tool availability, e.g. the
`obsidian` MCP server, was fixed at that session's startup). **Switching
does not migrate content between backends** — it only changes which one
new activity gets written to and which index gets injected at session
start.
