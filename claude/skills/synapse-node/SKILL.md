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

1. **Read the node.** `mcp__obsidian__vault_read` on the node file.
2. **Check `stale`:**
   - Already `true` → skip straight to Regeneration below, no hashing needed.
   - `false` → for each entry in `sources`, run `git hash-object {repo_root}/{path}` and compare to
     the stored `hash`. A single mismatch (including the command failing outright, e.g. the file
     was renamed or deleted) counts the same as a `stale: true` flag — treat the node as stale for
     this read regardless of what the frontmatter said.
   - No mismatch anywhere → the node is fresh. Use its content as-is, no further steps needed
     (skip Regeneration and the sweep below — those only ride along when *some* regeneration
     event actually occurs, and a clean node isn't one).
3. **Regeneration (only if step 2 found the node stale):**
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
   - **Never touch `## Notes`** — freeform content there is preserved verbatim across every
     regeneration, full stop.
   - Recompute `git hash-object` for each source, update `sources` in frontmatter, and rewrite
     `## Sources` to match — a plain bullet list of the same paths, no hashes (the human-readable
     mirror of frontmatter `sources`, since Obsidian's Properties panel flattens that list-of-objects
     field into an unreadable truncated string).
   - Set `stale: false`, `built_at` to machine local time (`date '+%Y-%m-%d %H:%M'`, never
     inferred).
   - Write the updated node back (`mcp__obsidian__vault_write` or targeted `vault_patch` calls),
     then use the freshly regenerated content for whatever prompted this read.
   - **Say out loud that a regeneration happened** — e.g. "Node '{title}' was stale, regenerated
     before use." This has real latency and token cost, unlike Tier 1/2's detection; it must never
     be absorbed silently into the read.
4. **Unassigned sweep (rides along on step 3, whenever any regeneration fires for this project):**
   - Read `synapse/{project}/_index.json`'s `_unassigned` array. Empty → nothing to do, skip
     silently (an empty sweep isn't worth announcing).
   - Otherwise read `synapse/{project}/Index.md` for the current node list (titles + summaries).
   - For each unassigned path, try `~/.claude/bin/synapse-tags.sh {path}` first as a fast
     pre-classification signal (same exit-code handling as Regeneration above), falling back to a
     full read for ambiguous cases, then classify against that node list:
     - **Fits an existing node** → append it (path + fresh `git hash-object`) to that node's
       `sources`, and set *that* node's `stale: true` for its own next read — do not regenerate it
       immediately as part of this sweep, only the node that triggered step 3 gets regenerated
       right now.
     - **Fits nothing** → leave it in `_unassigned`.
     - Update `_index.json` to reflect either outcome (move the key out of `_unassigned` into the
       claiming node's entry, or leave as-is).
   - **Announce every outcome**, same transparency rule as regeneration: which file, and which
     node it was attached to (or that it's still unassigned).
   - Sweep the **whole** bucket unconditionally, not just entries related to the node that
     triggered step 3 — an unrelated new subsystem rides along on any regeneration event
     happening anywhere in the project, by design (see the design note's Node Granularity &
     Grouping section).

## Guardrails

- Never skip the hash check just because `stale: false` looked plausible — Tier 1 only catches
  edits made through this Claude Code session; a `git pull`, branch switch, or externally-made
  edit is invisible to it and only Tier 2's hash comparison catches those.
- Never regenerate a node that passed its hash check — regeneration is real cost, reserved for
  actual staleness.
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
