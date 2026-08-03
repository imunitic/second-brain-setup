# Second brain as permanent memory

The user keeps a permanent, curated knowledge base — their "second brain" —
as a memory system separate from and complementary to the `~/.claude`
auto-memory system: use the second brain for durable, browsable
knowledge-base notes, not for session bookkeeping. It's an Obsidian vault,
running headless at login with the Local REST API plugin installed — see
"Querying the vault" below for how to reach it. A SessionStart hook
already injects the vault's `Index.md` at the start of every session, so
you shouldn't need to go read it yourself. Don't re-read it reflexively,
but do treat its injected contents as live information, not background
flavor.

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
  writing a new note, search for related existing notes (see "Searching
  notes" below) and link to them — prefer linking over duplicating content
  every time a related note exists. If genuinely nothing else applies,
  link the new note back to the index itself rather than leaving it an
  orphan with zero backlinks.
- **Split growing notes rather than letting one balloon.** During a long
  session (e.g. a multi-hour debugging or optimization effort), don't just
  keep appending every new finding to the same note indefinitely. Once a
  note is accumulating genuinely separate findings/topics rather than one
  cohesive update, split the new material into its own linked note instead
  of growing the original further. A handful of focused, well-linked notes
  is more useful later than one sprawling one — easier to search, easier to
  link into from elsewhere, easier to skim.
- Folders: `projects/` (dev-log notes tied to a specific coding project),
  `research/` (standalone research/reading notes), `scratchpad/`
  (throwaway/in-progress notes), `inbox/` (doesn't cleanly fit the
  others). Agents may create new folders beyond these, but folder depth is
  capped at two levels (`folder/subfolder`, never deeper). Creating a new
  top-level folder requires adding a matching entry to `Index.md` in the
  same action — the index must never fall behind what's actually on disk.
  If nothing about a note fits an existing or obviously-new category, put
  it in `inbox/` rather than forcing a bad fit or inventing a folder for a
  one-off.

## Querying the vault

Obsidian runs headless at login (via a startup plugin) with the Claude
vault already open, and the Local REST API plugin is installed there —
this is the only valid way to query the vault, and it always targets
whichever vault is currently open in the running Obsidian instance, not a
hardcoded path. The `obsidian` MCP server wraps that REST API. Do not
resolve or care about `$OBSIDIAN_VAULT_DIR` (see
`~/.claude/second-brain.conf`) unless the MCP tools are erroring or
unavailable and you must fall back to grepping files on disk directly —
that path variable matters only for that fallback case, since the vault
is also reachable as plain files on disk at that location.

If a project's `.claude.json` `mcpServers.obsidian` entry ever diverges
from the user-scoped one (e.g. points at the wrong vault path via a stdio
`obsidian-mcp` package instead of the REST API), that's a bug in that
project's config, not a second-brain routing choice — fix it by removing
the project-level override so the correct user-scoped REST API server
applies.

- You may create and edit notes in this vault **without asking for
  permission first**, as long as each note is placed in the folder
  matching its category per `Index.md`.
- Filenames are human-readable titles (not timestamp-prefixed — Obsidian's
  sidebar/graph display the filename directly, so a timestamp prefix reads
  poorly there). Sanitize filesystem-illegal characters (`/ : * ? " < > |`)
  but otherwise keep the title as-is.
- Frontmatter carries what the filename no longer does: `title`, `created`
  (real timestamp at creation time), and for task notes `task_id` /
  `status` (`TODO`/`IN-PROGRESS`/`REVIEW`/`DONE`/`CANCELED`).
- Link with Obsidian wikilinks: `[[filename]]` or `[[filename|display
  text]]` (no extension, exact filename minus `.md`).
- **Never hard-wrap note bodies.** Write each paragraph and each list item
  as one single unbroken line and let Obsidian soft-wrap it. Manually
  wrapping prose at ~80 columns (the habit that fits source code) makes
  notes painful to edit in Obsidian: reflowing after a small edit means
  rewrapping the whole paragraph by hand, and the stray newlines show up
  as noise in diffs and search context. Line-based constructs — table
  rows, headings, frontmatter, code blocks — keep their own line breaks.
- Create notes via the `/sb-note` command; task-tracking notes are
  additionally managed by the `sb-task` skill (proactive status
  transitions via the `status:` frontmatter field).

## Searching notes

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

# Git commits

Do not add a `Co-Authored-By: Claude ...` trailer to commit messages.
Enforced via `attribution.commit: ""` in `~/.claude/settings.json`, which
suppresses it mechanically — this note is a backstop in case that setting
ever gets reverted or overridden by a project-level settings file.
