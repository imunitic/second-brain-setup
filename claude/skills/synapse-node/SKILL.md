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

4. **Regeneration (only if step 1 or 2 found the node stale).** You re-author the prose; a script
   writes the file. **The node contract itself — frontmatter fields, the crux pointer, `## Links`,
   `grounded_in` — is the `synapse-node-format` skill**, shared with `/synapse-init` and
   `/synapse-rebuild`. What follows here is only what differs when *re*-authoring an existing
   node rather than writing a new one. Everything mechanical — hashes, `sources_digest`, the `## Sources` mirror,
   `built_at`, `commit`, `stale: false`, and preserving `## Notes` — belongs to
   `synapse-write-node.sh`, because a hub node's `sources` can no more be *emitted* into a tool call
   than read into a window. Let `$W` be the project's work directory,
   `~/.claude/synapse-work/{repo}@{branch}/`.

   - **Get the node's path list into a file, never into context:**

     ```sh
     ~/.claude/bin/synapse-query.sh sources "{Node title}" > "$W/paths.txt"
     ```

     If `$W/manifest.tsv` exists (or the namespace has `_manifest.tsv`), prefer re-running
     `~/.claude/bin/synapse-build-lists.sh` instead and use the regenerated `lists/NN.txt`: it
     re-derives every list from the clustering patterns, so files *added* since the last build are
     picked up automatically rather than sitting in `_unassigned`. `synapse-query.sh sources` can only
     return what the node already claims.
   - Consult `synapse/{project}/_profile.txt` if it exists — the aggregations that proved useful for
     this repo, and the negative results (searches that came back empty) worth not re-deriving.
   - **Prefer patching the prose from the diff over re-reading the node's sources.** If the node has a
     `commit` and only a small fraction of its files changed, read the current prose
     (`synapse-query.sh body`), get `git diff --name-status -M <commit>..HEAD` for its paths, and read
     hunks only for a bounded selection — always including `crux_path`, the file the crux was cut from.
     Amend the sentences the diff contradicts and keep the rest verbatim. A node covering 15,000 files
     where 12
     changed already has prose encoding the other 14,988, and re-reading them all both costs enormously
     and discards findings the diff has nothing to say about. Project the diff as carefully as
     `sources`: names first, `--stat` to size it, hunks only for the selection.
   - Fall back to reading the files when patching cannot be justified — a large fraction changed, the
     `crux` file is gone, or the baseline is unusable. Then try `~/.claude/bin/synapse-tags.sh {path}`
     first (exit 0 use the tags, exit 1 fall back to reading the file, exit 2 run the discovery
     procedure `/synapse-init` documents, then retry), and read the load-bearing files in full — the
     tags signal informs regrouping, it never substitutes for reading a file before rewriting its prose.
     If this is happening across many nodes at once, stop and run `/synapse-rebuild` instead: that is
     the instrument for major drift, and it triages node by node rather than paying full cost for each.
   - Re-author `## Summary`, `## Crux` and `## Links` to match what the files contain now, into
     `$W/body.md`. Re-check the node's one-line `summary` as well; keep the existing one with
     `synapse-query.sh field "{Node title}" summary` if it still fits.
   - **`## Crux` goes back as a directive, never as the code you just read.** `synapse-query.sh body`
     returns the *expanded* crux — the fenced block the writer sliced last time — so copying it forward
     stores a quote of an older version of the file as though it were current. Emit
     `<!-- crux: <path> <start>-<end> -->` and let the writer cut it out again. Reuse the recorded
     pointer (`synapse-query.sh field "{Node}" crux_path` and `crux_lines`) when that file did not
     change; pick a fresh span when it did, because the old line numbers may now land somewhere else.
     `<!-- crux: none -->` if nothing focal remains — and a node with no `crux_path` had none already.
   - **Re-emit the groundings, or they are lost.** `grounded_in` lives in frontmatter and the writer
     strips its directives from the body, so a recovered body carries none of them: writing it back
     without re-emitting drops the node's whole provenance silently. Recover the pointers with
     `synapse-query.sh grounding "{Node}" --list` (prints `path<TAB>lines`) and put a
     `<!-- grounded_in: <path> <lines> -->` back for each. Run `synapse-query.sh grounding` first: a
     `moved` line gives you the corrected range to use, and a `changed` line marks evidence that no
     longer says what the summary claims — re-point that one, and fix the sentence resting on it.
   - **Write it back with the script:**

     ```sh
     ~/.claude/bin/synapse-write-node.sh --title "{Node title}" --summary "{one line}" \
        --paths "$W/paths.txt" --body "$W/body.md"
     ```

     It replaces only the generated region and re-emits everything after the closing fence verbatim,
     which is what makes the `## Notes` guarantee enforceable rather than a promise.
   - **Never hand-write the frontmatter**, with `vault_patch` at `targetType: frontmatter` or
     otherwise. Two reasons, both load-bearing: that patch re-serialises the whole YAML block and
     YAML-coerces values (verified: an all-digit `hash` became `1.1111111111111112e+39`), and
     enumerating fields by hand is how `summary` and `commit` get silently dropped — which then breaks
     the next `synapse-build-project-index.sh` run, far from the cause.
   - **`## Notes` is human-authored only.** Never write into it — not at regeneration, not to record
     what you just did. (Task notes in `projects/` are a different artifact: the `synapse-task` skill *does*
     append there. Do not carry that habit into a Synapse node.)
   - If the node's `summary` or title changed, rebuild the index so the map matches:
     `~/.claude/bin/synapse-build-project-index.sh`.
   - **Say out loud that a regeneration happened** — e.g. "Node '{title}' was stale, regenerated
     before use." This has real latency and token cost, unlike Tier 1/2's detection; it must never
     be absorbed silently into the read.
5. **Unassigned sweep (rides along on step 4, whenever any regeneration fires for this project):**
   - Read the bucket with a shell command, not into context — `_index.json` runs to tens of megabytes:

     ```sh
     jq -r '._unassigned[]' "$OBSIDIAN_VAULT_DIR/synapse/{project}/_index.json"
     ```

     Empty → nothing to do, skip silently (an empty sweep isn't worth announcing).
   - Otherwise read `synapse/{project}/Index.md` for the current node list (titles + summaries).
   - For each unassigned path, try `~/.claude/bin/synapse-tags.sh {path}` first as a fast
     pre-classification signal (same exit-code handling as Regeneration above), falling back to a
     full read for ambiguous cases, then classify against that node list. **The judgment is which
     cluster a path belongs to; the bookkeeping is not yours to do:**
     - **Fits an existing node** → widen that node's line in `$W/manifest.tsv` so the pattern claims
       it, then re-run `synapse-build-lists.sh`. Set that node's `stale: true` for its own next read
       rather than regenerating it now — only the node that triggered step 4 is regenerated
       immediately. If there is no manifest, add the path to that node's list file instead.
     - **Fits nothing** → leave it unassigned. A genuinely new subsystem wants its own manifest line
       and its own node, which is `/synapse-init` work, not a sweep.
     - Then rebuild the projection with `~/.claude/bin/synapse-build-index.sh`. **Never hand-edit
       `_index.json`** — it is derived, and at tens of megabytes it cannot be rewritten through a tool
       call anyway.
   - **Announce every outcome**, same transparency rule as regeneration: which file, and which
     node it was attached to (or that it's still unassigned).
   - Sweep the **whole** bucket unconditionally, not just entries related to the node that
     triggered step 4 — an unrelated new subsystem rides along on any regeneration event
     happening anywhere in the project, by design (see the design note's Node Granularity &
     Grouping section).

## Guardrails

- `stale` is the right check for *this* procedure, but know what it cannot tell you: a file in no
  node's `sources` is invisible to it, and a renamed file reads as "gone". `synapse-query.sh drift`
  answers both, by diffing each node's recorded `commit` against HEAD. It is not on this hot path on
  purpose — reading one node's body should not pay for a repo-wide coverage audit — so reach for it
  when orienting after a `git pull` or a branch switch, and leave the systematic case to a deliberate
  refresh rather than a read.
- Never skip `synapse-query.sh stale` just because `stale: false` looked plausible — Tier 1 only catches
  edits made through this Claude Code session; a `git pull`, branch switch, or externally-made
  edit is invisible to it and only the script catches those.
- Never hand-roll the verification by reading `sources` or `_index.json` — that is the whole reason
  the script exists, and doing it manually costs tens to hundreds of thousands of tokens.
- Never hand-write a node's frontmatter or `## Sources` mirror. `synapse-write-node.sh` owns them, and
  writing them by hand both cannot scale to a hub node and silently drops `summary`/`commit`.
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
