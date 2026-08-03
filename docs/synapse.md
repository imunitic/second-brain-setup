# Synapse: the per-repo code graph

Claude Code re-explores a codebase from scratch every session — grep a term, open a file, follow
an import, back out, try again — and whatever it learns dies with the session. Synapse is a small,
LLM-authored map of a repo's subsystems (summary + crux + typed links per concept), hosted in the
second brain vault instead of a repo-local folder, so it's global across every project and
searchable the same way any other note is. It's inspired by
[NanoNets/Graft](https://github.com/NanoNets/Graft) but deliberately much smaller in scope — single
consumer (Claude Code only), no multi-agent wiring, no standing CLI surface.

![Synapse two-tier staleness and tree-sitter acceleration](diagrams/synapse-tiers.png)

## Dormant until opted in

A project has no Synapse namespace at all until `/synapse-init` is run inside it, deliberately.
Every other Synapse mechanism's cost is gated behind that namespace existing — the `SessionStart`
hook's check is a plain path lookup, never a model call, so a project that never opts in pays
nothing, forever.

## `/synapse-init`: first build

Walks the repo's tracked files (`git ls-files`, so `.gitignore` exclusion is free), runs a
per-file-summary-then-clustering pass biased by `CLAUDE.md`/`README.md` if present (hints, never
authoritative structure), and writes:

- One node file per subsystem/concept — a few dozen per repo, not one per file — under
  `synapse/{repo-name}/{Node Title}.md`. Each carries `sources` (**every** file the node covers, as
  a repo-relative path + `git hash-object` fingerprint), `sources_digest` (sha256 over the `LC_ALL=C`
  sorted `path:hash` lines, so "has this node changed" is one comparison rather than N), a
  plain-English `summary`, a `crux` (the few lines that carry the actual logic, stored as quoted text
  so it survives line drift, not line numbers), typed `links` to other nodes, an aggregated
  `## Sources` mirror, and a `## Notes` section preserved verbatim across every future regeneration.

- `_index.json` — a derived, machine-only reverse index (source path → owning node filenames, plus
  an `_unassigned` bucket for anything not yet claimed) that the cheap staleness hook can look up
  directly, without reasoning about anything.
- `synapse/{repo-name}/Index.md` — the human/Claude-facing map: node titles, one-line summaries,
  and a `remote` field (the repo's git remote, or its absolute path if it has none) used to detect
  a rare same-basename collision between two unrelated repos.

Re-running it on an already-initialized project doesn't rebuild anything — it's just the manual
fallback for sweeping the `_unassigned` bucket, for a repo that's gone fully dormant with no other
regeneration event to piggyback the sweep onto.

### `sources` is a machine field; `## Sources` is its human mirror

Worth stating plainly, because conflating the two produced a real bug (fw-core's first build trimmed
`sources` to ~5 "representative" files per node to keep the frontmatter readable):

- **`sources` is exhaustive, and read by machines only.** It is what Obsidian's search index turns
  into a file → node lookup: searching a class name that appears in no node's prose still finds the
  owning node, because the path is in that list. Trimming it silently destroys that lookup, leaves a
  node unable to answer "which files am I about", and reduces verification to whatever survived the
  trim. Its unreadability in Obsidian's Properties panel is not a reason to trim it — that is what
  the mirror is for.
- **`## Sources` is aggregated, not enumerated**: one line per owning directory/module with a file
  count. A node covering 941 files would otherwise put 75 KB of paths in front of a reader who wants
  to know which modules are involved.
- **`## Notes` is human-authored only.** Claude never writes there, at build or regeneration.
- Everything the generator owns sits between `<!-- synapse:generated:start -->` and
  `<!-- synapse:generated:end -->`. Regeneration replaces only the bytes between those markers and
  re-emits everything outside verbatim — which is the mechanism behind the `## Notes` guarantee.
  Without a fence, "preserved verbatim" is a promise with nothing enforcing it.

## What a session is told at startup

The `SessionStart` hook injects two things, and neither is stored anywhere:

- **A verified pointer to the cwd repo's own namespace**, emitted only when that namespace's `remote:` matches the repo's actual remote. On a mismatch it says so instead, rather than risk pointing at a different repo's graph.
- **A catalogue of every *other* namespace in the vault** (`name | remote`), because one session routinely spans several repos — a change in one landing in another — and without it only the starting repo is ever announced. A session that moves into a listed repo can consult its graph, after verifying the listed remote against that repo's own.

The catalogue is derived, never stored: the source of truth is the directory listing plus each namespace `Index.md`'s existing `remote:` field, so there is nothing to invalidate and it cannot drift from reality. A stored copy could be *wrong*; a derived one can only be absent. It also keeps this hook read-only against the vault — only `synapse-staleness.sh` writes.

Cost is one `grep` fork regardless of namespace count (`-m1` stops inside each file's frontmatter), then `LC_ALL=C sort` so the injected text is byte-identical across runs and machines — collation is locale-dependent and the glob's order isn't reliably sorted, and non-deterministic context defeats prompt caching. Deliberately `grep` rather than `rg`: this ships to machines that may not have ripgrep, and rg measured ~2.9x slower on this workload anyway, being pure process-startup cost.

Outside any git repo there is no pointer and nothing to exclude, so the catalogue lists everything. With no namespaces at all, nothing is emitted — the zero-cost path for repos that never opted in.

## Two-tier staleness

**Tier 1 — `PostToolUse` → `synapse-staleness.sh`.** Fires on every `Write`/`Edit`/`MultiEdit`.
Resolves the repo root **from the edited file's own directory**, not the session's cwd, so a session
spanning several repos flags the right namespace in each. Looks the edited path up in that repo's
`_index.json`: if it belongs to one or more nodes, rewrites each one's `stale:` line to `true`; if
it's not in the index at all, appends it to `_unassigned` instead. No hashing here — the hook already
knows with certainty which file just changed, so this tier is pure bookkeeping, not verification.

The hook also refuses to write when the namespace's `remote:` doesn't match the repo's, using the same origin → first-listed-remote → repo-root resolution the SessionStart hook and `synapse-query.sh` use. A namespace with no readable `remote:` counts as a mismatch, not a match on the empty string: absent provenance is not permission to write. All three components must resolve the remote identically, or one refuses where another proceeds.

It sets that field by **read-modify-write** (`GET`, rewrite the one `stale:` line, `PUT`), never by
`PATCH` with `Target-Type: frontmatter`. That call is not field-local despite reading that way: it
re-serialises the whole YAML block, stripping quotes, folding long `title:` lines, and YAML-coercing
values by type inference — verified, an all-digit `hash` came back as `1.1111111111111112e+39`. A
corrupted hash makes `sources_digest` disagree with its own `sources` permanently, so that would be a
false positive no rebuild can clear.

**Tier 2 — read-time, the `synapse-node` skill.** Not a hook — a procedure Claude follows itself,
proactively, whenever a node's body is about to actually be used (not a title-only skim). It runs
`claude/bin/synapse-query.sh stale`, which verifies the **whole project in one pass** — one
`git hash-object` fork plus one GET per node, ~1.5s for 51 nodes — and prints one line per stale node
with a reason (content changed, source files gone by name, no digest, node file missing), or nothing
at all when everything is current. Its exit 1 means "could not verify", not "clean".

This is deliberately a script rather than something Claude does by hand: recomputing a digest needs
the node's path list, and both places it lives are ruinous to read into context — a hub node's own
`sources` runs to ~38k tokens and `_index.json` to ~350k. Done in a script, the only thing reaching a
context window is the list of stale titles. Tier 2 is what catches everything Tier 1 can't see by
construction: edits made outside a Claude Code session, `git pull`, branch switches.

**Reading a node never reads its frontmatter.** Consultation wants the prose, not the path list, so
the procedure finds the closing `---` and reads from the line after it — ~900 tokens whether the node
covers 5 files or 941. A full `vault_read` of a hub node is a mistake, not merely expensive.

Regeneration re-reads the node's current sources, rewrites `summary`/`crux`/`links` and the
aggregated `## Sources` mirror (never `## Notes`, and only inside the generated fence), recomputes
every hash plus `sources_digest`, and is always announced out loud — it has real latency/token cost,
unlike the cheap detection step, so it's never absorbed silently into a read. The same event
unconditionally sweeps the whole `_unassigned` bucket too, not just entries related to whatever
triggered the regeneration — classifying each file against the existing node list and attaching or
leaving it unassigned, announcing either outcome.

## Optional tree-sitter acceleration

`claude/bin/synapse-tags.sh` is a narrow, purely mechanical helper both `/synapse-init` and the
`synapse-node` skill try before doing a full read: given a file, it prints `tree-sitter tags`
output — real definitions and name-based call references, extracted by parsing, not text
guessing — cutting straight to clustering/regeneration signal without reading the file's full body.

It's optional at every layer, never a hard dependency:

- **Grammar registry** (`~/.claude/synapse-grammars.conf`) is self-populating, not hand-curated.
  The first time a never-seen file extension shows up, Claude runs a one-time discovery procedure
  (try `github.com/tree-sitter/tree-sitter-{lang}`, fall back to a web search, verify the repo
  actually ships a tags query before trusting it) and caches the result — positive or
  `{"unsupported": true}` — permanently, across every future project, not just the one that
  triggered it.
- **Exit codes are the whole contract**: `0` → tags printed, use them; `1` → not usable right now
  (missing `tree-sitter`, no C compiler, a confirmed-unsupported language) — fall back to reading
  the file directly, silently; `2` → never-seen extension, run discovery once, then retry.
- Grammars build as native libraries (`tree-sitter build`, no `--wasm` — WASM was tried and
  rejected: the CLI needs a non-default Rust build to *consume* WASM grammars, which is a worse
  dependency than the C compiler needed to build native ones).

Every one of these fallback paths was verified directly, not assumed — including catching and
fixing a real bug where a qualified-path reference (`Eon_ecs.Foo.bar`) got double-counted as a bare
same-package reference, producing edges that didn't actually exist in the code.
