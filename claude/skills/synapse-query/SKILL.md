---
name: synapse-query
description: This repo has a Synapse code graph. For ANY task here — understanding how something works, finding where code lives, tracing what depends on a file, or scoping an edit — consult synapse/{project}/Index.md and synapse-query.sh before grepping or reading source files. Grep only after Synapse has named the exact file(s) to read.
---

# Synapse Query: Day-to-Day Use of the Code Graph

`synapse-node` covers Tier 2 staleness checking and regeneration. `synapse-task` covers task-note
status transitions. This skill is neither of those — it's how to actually *use* the graph for an
ordinary task: understanding a subsystem, finding where something lives, or scoping an edit before
touching code. If a query below turns up a stale node, hand off to `synapse-node`'s procedure rather
than reasoning about staleness here.

## Why this exists

The Synapse graph has two parts:

1. **The graph itself** — `synapse/{project}/*.md`, one node per subsystem/concept, LLM-authored:
   a plain-English summary, a crux (the few lines that actually carry the logic), typed relations to
   other nodes (`depends_on`/`part_of`/`uses`/etc, as the node's own data), and an exhaustive
   `sources` list. A broad metadata layer for narrowing down *where* to look — not a replacement for
   reading code, a map to it.
2. **`synapse-query.sh` and friends** — scripts that query and extract from part 1 cheaply. Nothing
   here is a daemon or a server; every command is a plain script reading files on disk.

**The point of this graph is to make grep the last resort, not a peer option.** Consult Synapse
first to learn *where* something lives; a node's `sources` (or `crux_path`, if it has one) then
names the exact file(s) to fetch; grep only re-enters at that point, scoped to a file Synapse
already named, to locate a specific detail inside it — never as an unscoped repo-wide search run
instead of asking Synapse first. If you catch yourself about to grep the whole repo before checking
`synapse/{project}/Index.md`, stop and check the index instead.

**Why the cost difference is real, not just tidiness.** `synapse-query.sh body <node>` never goes
through Obsidian's API — it's a direct disk read that extracts only the prose between the generated
fences, skipping the node's `sources` list entirely. On a hub node, going through the API instead
would move that node's entire frontmatter — megabytes — to print a few hundred words. On a large
repo (dozens to hundreds of thousands of tracked files), that difference is the entire reason a
query stays cheap instead of dominating the turn.

## The tools

Not "what's missing versus other code-graph tools" — every capability you'd expect already maps to
something that exists, composed from Synapse plus what Claude Code already has, no new binary
required:

| Need | Reach for | Why |
|---|---|---|
| "Where does X live?" (ranked, natural-language) | `mcp__obsidian__search_simple`/`search_query` over the vault, plus a first read of `synapse/{project}/Index.md` | Full-text, relevance-ranked. Not semantic ranking, but genuinely comparable for locating a concept. |
| Every occurrence of a pattern | native `grep`/`rg`, **scoped to a file Synapse already named** | Not a repo-wide first move — the deterred, last-resort case. See "Why this exists" above. |
| A file's API surface | `Read` the file directly | Claude already has direct, cheap filesystem access — no separate view needed. |
| Who depends on a subsystem, or what it depends on | `synapse-query.sh links "{Node}" --inbound` / `--closure` | Real transitive-closure traversal over the typed relations, at node granularity. |
| **Who calls this method/class, repo-wide** | `synapse-query.sh callers <name>` | Every call site as `path:line ⇥ calling expression`, off the flat index `synapse-build-refs.sh` projects from the tags cache. 0.36s against a 1.4 GB index. Needs **no node and no graph** — it works in a repo `/synapse-init` has never touched, as long as the cache is filled. Still name-based rather than type-resolved, so hits are candidates with evidence: the calling expression is on the line, which usually settles the receiver without opening the file. |
| One frontmatter scalar (`stale`, `built_at`, `commit`, ...) | `synapse-query.sh field "{Node}" <key>` | Cheap, targeted extraction — never reads the rest of the node. |
| A node's prose, without its (possibly huge) `sources` list | `synapse-query.sh body "{Node}"` | Disk read, never the API; skips frontmatter and `## Notes`. See the cost note above. |
| Every file a node covers | `synapse-query.sh sources "{Node}" [--count\|--modules\|--filter <p>]` | Filtered/counted/grouped, never the raw megabyte-scale list. |
| Is this node's understanding still accurate? | `synapse-query.sh stale` / `drift` / `grounding` | Hand off to the `synapse-node` skill's procedure — this skill doesn't re-explain that. |

## Usage scenarios

| When you're... | Reach for | Not |
|---|---|---|
| Orienting on an unfamiliar repo | `synapse/{project}/Index.md`, then the relevant node's `body` | grepping around to build a mental map by hand |
| Understanding a flow ("how does X work") | `synapse-query.sh body "{Node}"` for the node that covers it | reading every file the flow touches, cold |
| Finding where a change belongs | `search_simple`/`Index.md` to find the owning node, then that node's `sources`/`crux_path` for the exact file(s) | a repo-wide grep for a guessed symbol name |
| Judging blast radius before an edit | `synapse-query.sh links "{Node}" --inbound` (or `--closure` for transitive) | assuming nothing else depends on it |
| You already know the exact file and line range | just fetch it (`sed`/`Read`) | asking Synapse a question you can already answer |
| Finding every occurrence of a literal pattern | native `grep`/`rg`, scoped to files Synapse already named | an unscoped repo-wide grep before consulting Synapse at all |
| A node turns up `stale` | hand off to the `synapse-node` skill | trying to reason about staleness inline here |

## When a node isn't enough

Synapse has no exact per-symbol call graph — a node's answer is a concept-level summary, not a
parse. This matters more here than it would for a tool that does have one: short, reused names
(common in languages that don't require import qualification for same-package references) can't
always be disambiguated from a node alone. When a node's `crux`/`grounded_in`/`sources` don't
resolve the specific symbol-level question:

1. Fetch the file(s) the node already named via `sources` or `crux_path` — not a fresh search.
2. Grep or read within that known file for the specific detail. This is the expected, first-class
   fallback, not a rare edge case — treat it as normal, not as Synapse having failed.
3. If the file Synapse named doesn't exist on disk, the graph is ahead of your checkout (a branch
   switch or an unpulled move) — don't read a missing file; the `synapse-node` skill's staleness
   procedure is what to run, not a workaround here.

## Guardrails

- **Never grep the whole repo before checking `synapse/{project}/Index.md`**, unless this repo has
  no Synapse namespace at all (`vault_list` on `synapse/{project}/` comes back empty — in that case
  there's nothing to consult, say so and proceed normally).
- **Never treat a node's summary as ground truth for a symbol-level claim** it wasn't built to make
  precisely — see "When a node isn't enough" above.
- **Never `vault_read` a node just to read its prose.** That pulls the full frontmatter, which can
  run to megabytes on a hub node. Use `synapse-query.sh body` (see the cost note above).
- **Never reason about a node's staleness inline in this skill.** Hand off to `synapse-node`'s
  procedure — that's its job, not this skill's.
- **Never treat `synapse-query.sh`'s exit 1 as "clean."** It means the check could not run (no
  vault, no namespace for this repo, a `remote:` mismatch) — not that the graph verified fine.
