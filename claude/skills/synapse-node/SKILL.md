---
name: synapse-node
description: Tier 2 staleness check and lazy regeneration for a Synapse code-graph node, run whenever a node's body is about to be read and used — not a hook, a procedure Claude follows itself.
---

# Synapse Node Read: Staleness Check, Regeneration, Unassigned Sweep

Built by `/synapse-init`, kept flagged stale at edit time by the `PostToolUse`
hook (`synapse-staleness.sh`, Tier 1). This skill is Tier 2 — the authoritative, lazy check that
fires only when a node's content is actually about to be consumed, never on a schedule and never
speculatively.

## When to invoke (proactive — do not wait to be asked)

Whenever a `synapse/{project}/{Node}.md` file is about to be read **for its content to actually be
used** (orienting on a subsystem, answering a question about it, deciding where to make a change)
— not for a `vault_list`/title-only skim. Run this procedure *before* trusting what comes back from
that read. This is the one Synapse mechanism that isn't a hook: a hook is a plain script with no
reasoning, and classifying whether a file "fits" a node is exactly the kind of judgment call that
needs one.

## Procedure

1. **Verify the whole project once, with the script.** Run `~/.claude/bin/synapse-query.sh stale` from
   inside the repo. It prints one `{node title}\t{reason}` line per stale node and nothing at all
   when everything is current, so its output is the complete stale set for the project.

   Do this **once** per orienting task, not once per node: it costs a single `git hash-object` fork
   plus one GET per node (~1.5s for a 51-node project), and covers every node at once. Re-run only
   after source files have actually changed since the last run.

   Never do this by hand instead. Recomputing a digest needs the node's path list, and both places
   it lives are ruinous to read into context — a hub node's own `sources` runs to ~38k tokens and
   `_index.json` to ~350k. The script exists so the only thing reaching a context window is the list
   of stale titles.

   **Exit 1 means "no information", not "clean."** It signals a missing dependency, no vault, no
   namespace for this repo, or a `remote:` mismatch. Do not treat that as a passing verification —
   either fix the cause or proceed knowing the graph is unverified, and say which.

2. **Also honour the Tier 1 flag.** `rg -m1 '^stale:' "$OBSIDIAN_VAULT_DIR/synapse/{project}/{Node}.md"`
   — one line, negligible cost. The two tiers catch different things: Tier 1 flags edits made through
   this Claude Code session the moment they happen, the script catches everything including changes
   the hook never saw (`git pull`, branch switch, rebase, an IDE edit). **Either one saying stale
   means stale.** A node named by neither is fresh — use its content as-is and skip Regeneration and
   the sweep, which only ride along when some regeneration actually occurs.
3. **Read the node's body, never the whole file.** `sources` is exhaustive — every file the node
   covers, each with a hash — so a hub node's frontmatter alone can run to ~38k tokens while its
   actual prose is under 1k. Consultation never needs `sources`; the script handles verification.
   So skip the frontmatter entirely:

   ```sh
   ~/.claude/bin/synapse-query.sh body "{Node title}"
   ```

   That prints only what is between the generated fences — so it excludes `## Notes` as well as the
   frontmatter, which a raw offset read would not — and costs ~500 tokens whether the node covers 5
   files or 941. **A full `mcp__obsidian__vault_read`
   of a hub node is a mistake, not merely expensive** — it spends tens of thousands of tokens on a
   path list you are not going to use. Use `vault_read` only when you specifically need the
   frontmatter or the links/backlinks metadata it returns.

   Finding *which* node to read is a separate job, and search does it: because `sources` is
   exhaustive, `mcp__obsidian__search_simple` on a class or file name locates the owning node even
   when that name appears nowhere in any node's prose, and returns snippets rather than whole files.

   For the other questions about a node, use the same tool rather than reading frontmatter:
   `synapse-query.sh sources "{Node}" --count|--modules|--filter <p>` for what it covers, and
   `synapse-query.sh field "{Node}" <key>` for a single scalar such as `stale` or `built_at`.

4. **Regeneration (only if step 1 or 2 found the node stale):**
   - For each of the node's current `sources` files, try `~/.claude/bin/synapse-tags.sh {path}`
     first (exit 0 means use the tags directly, exit 1 means fall back to reading the file, exit 2
     means run the discovery procedure `/synapse-init` documents, then retry). This keeps the
     tag-derived structural signal as fresh as the rest of the node, not just accurate at first
     init.
   - Re-read the node's current `sources` files from disk (in full, regardless of what the tags
     signal gave — that signal informs regrouping decisions, it never substitutes for actually
     reading a file before rewriting its summary/crux prose).
   - Rewrite `## Summary`, `## Crux`, and `## Links` to match what the files actually contain now
     — same judgment `/synapse-init` used to write them the first time.
   - **Rewrite only the fenced region.** Everything the generator owns sits between
     `<!-- synapse:generated:start -->` and `<!-- synapse:generated:end -->`. The write is:
     read the file, replace *only* the bytes between those markers, re-emit everything outside them
     verbatim. That is the mechanism behind the `## Notes` guarantee — "preserved verbatim" is
     otherwise a promise with nothing enforcing it, and a whole-body rewrite is exactly how Notes
     content gets silently destroyed.
   - **`## Notes` is human-authored only.** Never write into it — not at regeneration, not at build
     time, not to record what you just did. It exists for a human to write in, and it lives outside
     the fence so the mechanism above already protects it. (Task notes in `projects/` are a different
     artifact: the `sb-task` skill *does* append there. Do not carry that habit into a Synapse node.)
   - Recompute `git hash-object` for **every** source, update `sources` in frontmatter, and recompute
     `sources_digest` (sha256 over the `LC_ALL=C` sorted `path:hash` lines, newline-joined, no
     trailing newline — the definition pinned in `/synapse-init`, which `synapse-query.sh stale` must be
     able to reproduce exactly).
   - Rewrite `## Sources` as the **aggregated** human mirror: one line per owning directory or module
     with a file count, `LC_ALL=C` sorted — not a path list. The exhaustive list lives in frontmatter
     for search; a reader wants to know which modules are involved, not to scroll 941 paths.
   - Set `stale: false`, `built_at` to machine local time (`date '+%Y-%m-%d %H:%M'`, never
     inferred).
   - Write the updated node back, then use the freshly regenerated content for whatever prompted this
     read. **Never write frontmatter with `vault_patch` at `targetType: frontmatter`** — it
     re-serialises the whole YAML block and YAML-coerces values (verified: an all-digit `hash` became
     `1.1111111111111112e+39`). Read-modify-write the file instead.
   - **Say out loud that a regeneration happened** — e.g. "Node '{title}' was stale, regenerated
     before use." This has real latency and token cost, unlike Tier 1/2's detection; it must never
     be absorbed silently into the read.
5. **Unassigned sweep (rides along on step 4, whenever any regeneration fires for this project):**
   - Read `synapse/{project}/_index.json`'s `_unassigned` array. Empty → nothing to do, skip
     silently (an empty sweep isn't worth announcing).
   - Otherwise read `synapse/{project}/Index.md` for the current node list (titles + summaries).
   - For each unassigned path, try `~/.claude/bin/synapse-tags.sh {path}` first as a fast
     pre-classification signal (same exit-code handling as Regeneration above), falling back to a
     full read for ambiguous cases, then classify against that node list:
     - **Fits an existing node** → append it (path + fresh `git hash-object`) to that node's
       `sources`, and set *that* node's `stale: true` for its own next read — do not regenerate it
       immediately as part of this sweep, only the node that triggered step 4 gets regenerated
       right now.
     - **Fits nothing** → leave it in `_unassigned`.
     - Update `_index.json` to reflect either outcome (move the key out of `_unassigned` into the
       claiming node's entry, or leave as-is).
   - **Announce every outcome**, same transparency rule as regeneration: which file, and which
     node it was attached to (or that it's still unassigned).
   - Sweep the **whole** bucket unconditionally, not just entries related to the node that
     triggered step 4 — an unrelated new subsystem rides along on any regeneration event
     happening anywhere in the project, by design (see the design note's Node Granularity &
     Grouping section).

## Guardrails

- Never skip `synapse-query.sh stale` just because `stale: false` looked plausible — Tier 1 only catches
  edits made through this Claude Code session; a `git pull`, branch switch, or externally-made
  edit is invisible to it and only the script catches those.
- Never hand-roll the verification by reading `sources` or `_index.json` — that is the whole reason
  the script exists, and doing it manually costs tens to hundreds of thousands of tokens.
- Never treat the script's exit 1 as a clean result. It means the check could not run.
- Never regenerate a node that neither the script nor its `stale:` flag named — regeneration is real
  cost, reserved for actual staleness.
- Never `vault_read` a hub node just to read its summary. Offset past the frontmatter (step 3).
- Never silently fold a regeneration or an unassigned-file attachment into normal output — both
  get an explicit, visible announcement line.
- `## Notes` content is sacrosanct across regeneration — if a rewrite would touch it, that's a bug
  in the regeneration step, not an acceptable side effect.

## Fallback if regeneration proves disruptive

If lazy per-read regeneration turns out to be too disruptive in practice (e.g. a single task
orienting against several stale nodes at once, each paying a regeneration cost), the documented
fallback (see the design note's Alternatives) is to downgrade staleness to a plain cache miss:
skip the stale node's content entirely and read its underlying source files directly instead,
leaving regeneration to a manual step. This is a deliberate escape hatch, not the default — only
switch to it if the default is causing real friction, and say so if you do.
