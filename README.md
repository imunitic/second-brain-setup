# Synapse

[![tests](https://github.com/imunitic/synapse/actions/workflows/tests.yml/badge.svg)](https://github.com/imunitic/synapse/actions/workflows/tests.yml)

Memory for Claude Code: durable notes that outlive a session, and a per-repo code graph so a
codebase does not get re-explored from scratch every time. Three components, independent enough that
you can use one without the others:

- **Synapse Vault** — an Obsidian vault holding the notes: research, decisions, project logs, design
  discussions. Cross-project by default and searchable as ordinary Markdown.
- **Synapse Graph** — a per-repo semantic code graph, hosted *inside* the Vault under
  `synapse/{repo}@{branch}/`, so it is stored and searched like any other note. Dormant until
  `/synapse-init` is run in a repo.
- **Synapse Tools** — the scripts, commands, skills and hooks that build and maintain both.

This repository packages the **Tools**, plus the templates and config they need. It does not contain
your notes: the Vault's content is a separate sync concern (git, Obsidian Sync, iCloud, manual copy —
your call).

## Synapse Vault — the notes

- `claude/CLAUDE.md` — the global memory-system instructions: when to write a note, where it goes,
  and the linking rules.
- `claude/synapse.conf.template` — path config; set `OBSIDIAN_VAULT_DIR` per machine.
- `claude/hooks/synapse-session-start.sh` — `SessionStart`: injects the Vault's index so every
  session starts with the map already in context, and points at this repo's Graph namespace if one
  exists (a plain path lookup, never a model call — a repo that never opted in pays nothing).
- `claude/hooks/synapse-stop-nudge.sh` — a turn-count-based `Stop` hook that forces a "worth
  capturing?" check-in every 25 turns.
- `claude/hooks/synapse-db-sync.sh` — commits Vault changes to the Vault's own local git repo,
  if one exists.
- `claude/commands/synapse-note.md` — note creation (bare / `--task` / `--list` / `--search`).
- `claude/commands/synapse-design-note.md`, `claude/commands/synapse-task-note.md` — a design-discussion →
  compiled-checklist pipeline that lives in the Vault (`designs/`, `projects/`) rather than a repo's
  gitignored `docs/notes/`, so it is cross-project by default. Task creation and status tracking
  delegate to `synapse-note.md --task` and `skills/synapse-task/`, not a separate mechanism.
- `claude/skills/synapse-task/` — proactive task-status tracking.

Two of the skills are knowledge rather than procedure, holding what several components need but none
owns: `claude/skills/synapse-node-format/` (the node contract, loaded by `/synapse-init`, the
`synapse-node` skill and `/synapse-rebuild`, all of which write nodes) and
`claude/skills/synapse-orientation/` (how to work out where meaning lives in an unfamiliar tree,
loaded by a first build and by rebuild's re-orient class, and useful on its own terms). A skill does
not have to *do* something — being loadable knowledge is the point, and it is what keeps one
description of the node format instead of three.

## Synapse Graph — the per-repo code graph

A few dozen LLM-authored node notes per repo, one per subsystem or concept, each carrying a
plain-English summary, a quoted `crux`, typed links, and the exhaustive list of files it covers.

- `claude/commands/synapse-init.md` — first-time build: an orientation pass, clustering into a
  `manifest.tsv`, then node notes plus the two derived projections. Also the manual
  `_unassigned`-sweep fallback for an already-initialized but dormant repo. The division it enforces:
  deciding *what the nodes are* and writing their prose is the model's job; enumerating, hashing,
  digesting and writing is the scripts'. `manifest.tsv` (`title <TAB> include-ERE <TAB> exclude-ERE`)
  is the seam, which is why coverage comes out as a printed number rather than a claim.
- `claude/commands/synapse-rebuild.md` — the manual repair for *major* drift: a branch switch, a long
  absence, a large merge. Sizes the job first, then triages each flagged node into **reseat** (renames
  only — recover the prose from the node itself, swap the paths, read nothing), **patch from the diff**
  (a small fraction of its *lines* changed — amend only the sentences the diff contradicts), or
  **re-orient** (the prose's premises are suspect). The principle: compute new prose from the diff,
  never by re-reading a node's sources, because a node covering 15,000 files where 12 changed already
  encodes the other 14,988.
- `claude/hooks/synapse-staleness.sh` — `PostToolUse` (`Write|Edit|MultiEdit`) Tier 1: flags the
  edited file's nodes `stale` (or queues a brand-new file into `_unassigned`) via the Local REST API
  directly, no MCP round-trip. It also re-verifies any `crux` or `grounded_in` range those nodes cite
  *in the file just edited*, and asks for a correction only when cited evidence stopped matching —
  free, because that is the one moment the code has certainly just been read.
- `claude/skills/synapse-node/` — Tier 2: the lazy staleness check, regeneration and unassigned sweep
  Claude runs itself whenever a node's body is actually read. A procedure, not a hook.

## Synapse Tools — the scripts

Every script prints its own usage for `--help`; `docs/scripts.md` is generated from those same header
blocks.

- `claude/bin/synapse-query.sh` — read-only queries, printing only what was asked for. `stale` is the
  Tier 2 check (one `git hash-object` fork plus one GET per node, comparing each node's
  `sources_digest` against a recomputed one). `drift` answers what `stale` structurally cannot: it
  diffs each node's recorded `commit` against HEAD, so it also sees **additions** (a path in no node's
  `sources` is invisible to a hash comparison by definition), reports renames as reseatable rather
  than as deletions, and costs one `git diff` per distinct baseline rather than a hash of every
  tracked file. `grounding` re-slices each recorded piece of evidence and distinguishes *moved* (fixable
  by re-pointing, no reading) from *changed* (a claim to re-check). `links` derives the typed relation
  graph a node's `## Links` section records — outbound, inbound, transitive closure, and `--check` for
  targets that resolve to no node, which Obsidian renders silently. `symbol <name> "{Node}"` is exact-name
  def/ref lookup across a node's sources — the last-mile step from "a node named the file" to a real
  `file:line`, backed by `synapse-tags-cache.sh` below rather than a fresh tree-sitter pass per query.
  `callers <name>` answers the complementary repo-wide question — every call site of an exact name, as
  `path:line ⇥ calling expression` — over the flat index `synapse-build-refs.sh` writes: 0.36s against
  syrius3's 1.4 GB index. It needs no graph at all (no nodes, no `_index.json`, no vault) and is
  dispatched ahead of the vault preamble so that stays structurally true rather than merely intended.
  None of them ever pull. `body` prints a node's fenced prose, `sources` its file list
  filtered/counted/grouped by module, `field` one frontmatter scalar. A script rather than direct reads
  because a hub node's `sources` is ~38k tokens and `_index.json` ~350k — everything a script reads
  internally is free, only its stdout costs tokens.
- `claude/bin/synapse-vocab.sh` — reduces a whole repo to `group ⇥ word ⇥ count`: every symbol name
  `tree-sitter` can see, split on CamelCase and snake_case, stopworded through the same list the
  prompt tokenizer uses, aggregated by directory. Evidence for clustering, so deciding what a
  subsystem is about costs symbol names rather than source lines — 7,778 code files in 4.3s, the
  whole of syrius3 in ~51s. Raw tags are never stored (~942 MB against 6.9 MB of vocabulary); each
  worker pipes `synapse-tags.sh --paths` straight into the reduction. An empty `groupwords.tsv` is a
  legitimate result — no file had a usable grammar — and is the signal to fall back to
  `synapse-orientation`, which is why it exits 0. `--lists` keys the same output by *cluster* instead
  of by directory, which is what `synapse-gate.sh` scores: a cluster is not generally a union of
  directories, so its vocabulary cannot be derived from the directory-keyed table afterwards.
- `claude/bin/synapse-rank.sh` — decides what is worth *reading* when authoring a node, in three
  tiers. Code ranks by **definitions per KB**: raw counts put generated tables and wide accessor
  classes first, and normalising by size moved a known crux from rank 17 to 7 of 574 on a real node.
  A declarative file ranks its **consumer** instead of itself — a declaration carries little meaning,
  the code binding it carries the domain verbs — resolved by stem plus module prefix, because generic
  stems (`Adresse`, `NatPerson`) match dozens of unrelated classes without the module constraint.
  Everything else scores zero. What counts as declarative is *derived*, not listed: a non-code file
  whose stem prefixes a code file's stem in the same module. Shipping a list of extensions would have
  meant shipping one project's vocabulary as if it were universal. Coverage is untouched — `sources`
  stays exhaustive, and this only sets reading order. `--pool` splits the two halves of authoring:
  the **summary** pool keeps everything, because a summary is made of *names* and test class names
  carry domain concepts nothing else surfaces (`Gegenpartei` and `Frist` came only from those); the
  **crux** pool is implementation only, since a crux is concentrated logic and density ranks tests
  high for a structural reason — many small `@Test` methods, each a definition, in a small file.
  What counts as a test is a conservative path/filename heuristic (`FooTest.java` yes, `Latest.java`
  no), replaceable wholesale with `$SYNAPSE_TEST_PATH_RE`.
- `claude/bin/synapse-gate.sh` — the one quality check `/synapse-init` never had. Coverage was
  already provable by regex expansion plus `comm`; whether a cluster corresponds to a *concept* was
  judgment, discovered only when someone tried to write its summary and found nothing to say. Reads
  a cluster-keyed vocabulary (`synapse-vocab.sh --lists`) and flags any cluster with at most one
  near-unique term in its top eight, where near-unique is `df <= max(2, N/20)` over N clusters.
  Deliberately counts rare terms rather than weighing them: ranking by tf-idf *sum* follows frequency
  rather than rarity and put two known-bad clusters near the top. Measured on the 46 nodes of
  `syrius3@master`, tolerance 1 caught all four undifferentiated clusters with no false positives.
  Empty output means every cluster is differentiated.
- `claude/bin/synapse-build-lists.sh` — enumerates tracked files (dropping binaries, lockfiles,
  minified output and submodule gitlinks) and expands `manifest.tsv` into one path list per node,
  printing `enumerated/covered/unassigned` so a bad pattern is a number rather than a silent gap.
  Works out of `$SYNAPSE_WORK_DIR`, default `~/.claude/synapse-work/{repo}@{branch}/` — never the repo,
  since these scripts run from inside it. Repo-specific exclusions come from
  `~/.claude/synapse-ignore-files.conf` (one ERE per line) OR'd with `$SYNAPSE_EXTRA_EXCLUDE_RE`, and
  files over `$SYNAPSE_MAX_FILE_BYTES` (default 1 MB) are skipped *and reported* — no extension or
  name rule anticipates a generated monster, and a silent skip would make `enumerated` disagree with
  the repo. Excluding a path removes it from the graph entirely: no owning node, no vault search hit,
  no staleness flag when it changes. That is right for build output and vendored code, and wrong for
  anything whose edits still matter — which is a separate question from whether it is worth *reading*.
- `claude/bin/synapse-write-node.sh` — writes one node: hashes every source, computes
  `sources_digest`, records the baseline `commit`, slices the `crux` out of the file from a line
  pointer, records each `grounded_in` range as a digest, builds the aggregated `## Sources` mirror, and
  PUTs it — re-emitting everything after the closing fence verbatim so `## Notes` survives. Refuses to
  write into a namespace whose `remote` belongs to a different repo. The caller supplies only prose and
  pointers: the "never a context read" rule is symmetric, and a hub node's `sources` can no more be
  emitted into a tool call than read into a window.
- `claude/bin/synapse-push-nodes.sh` — loops the writer over every node that has both a path list and
  an authored `b-NN.md`, taking each node's one-line `summary` from that file's frontmatter.
- `claude/bin/synapse-build-index.sh` — builds `_index.json`, the reverse index the Tier 1 hook reads
  (source path → owning node filenames, plus `_unassigned`).
- `claude/bin/synapse-build-project-index.sh` — builds `Index.md`, reading each bullet's headline back
  from that node's own `summary` field, so the map cannot describe a node as it used to be.
- `claude/bin/synapse-identity.sh` — sourced, not executed: the one place a namespace is named
  (`{repo}@{branch}`). The repo half comes from the *remote's* basename rather than the directory, so a
  linked worktree and its parent agree; the branch half from `git symbolic-ref --short HEAD`, which
  reports an unborn branch correctly and fails on a detached HEAD instead of returning the literal
  string `HEAD` the way `rev-parse --abbrev-ref` does. Worktrees need no handling of their own, because
  git refuses one branch in two worktrees of a repository — so a branch already names at most one
  checkout, and `.git`-file parsing, `commondir` walking and worktree-versus-submodule discrimination
  all become unnecessary rather than merely handled.
- `claude/bin/synapse-graph-clean.sh` — the only destructive tool here, and a command you run rather
  than a hook that fires. Removes namespaces whose branch had an upstream that is now gone (what
  `git branch -vv` shows as `[origin/x: gone]`), after a `git fetch --prune` — without which a deleted
  branch still has a local tracking ref and the whole thing silently no-ops. Anything it cannot
  positively confirm is *reported* rather than deleted: a branch absent locally whose upstream config
  went with it, or a namespace with no `branch` field. In a repo with no remote there is no upstream to
  consult, so it falls back to local branch existence — without that fallback the first run in a
  remoteless repo would read every namespace as deleted-upstream and wipe the lot. `--dry-run` prints
  the same verdicts and touches nothing.
- `claude/bin/synapse-tags.sh` — optional tree-sitter acceleration for clustering, regeneration and
  the `_unassigned` sweep: looks up a file's extension in a self-populating grammar registry
  (`~/.claude/synapse-grammars.conf`), clones and builds a native grammar on first need, and prints
  `tree-sitter tags` output (definitions plus name-based call references). Fails soft on any missing
  piece (`tree-sitter`, a C compiler, an unsupported language) — every caller falls back to reading the
  file directly, exactly as if this script did not exist.
- `claude/bin/synapse-tags-cache.sh` — keeps `$SYNAPSE_WORK_DIR/_tags_cache.json` (`path → {hash,
  tags}`, default `~/.claude/synapse-work/{repo}@{branch}/`) current for a set of files, piggybacked on the same per-file hash comparison node
  regeneration already performs rather than a separate staleness pass: unchanged paths are skipped,
  changed-or-missing ones are (re-)tagged one `synapse-tags.sh --paths` invocation per *chunk* rather
  than per file — 400 real Java files went from 10.26s to 1.39s, and the cache it produces is byte-for-byte
  the same. Chunks run in parallel via `xargs -P` (capped at the machine's core
  count), each worker writing its own result to a private temp file before one sequential merge writes
  the cache — never a worker writing the shared file directly. `synapse-write-node.sh` calls this as a
  byproduct of its own hashing; `synapse-query.sh symbol` calls it to lazily backfill whatever a node's
  cache hasn't reached yet. Disable entirely with `SYNAPSE_DISABLE_SYMBOL_CACHE`.
- `claude/bin/synapse-build-refs.sh` — projects that cache into `$SYNAPSE_WORK_DIR/_refs.tsv`, the flat
  `name ⇥ def|ref ⇥ kind ⇥ path:line ⇥ expression` index `synapse-query.sh callers` reads. A separate
  artifact because the constraint is *format*, not size: one `jq` pass over a 4.6 MB cache measured
  0.064s, which extrapolates to ~13s per query at syrius3's 942 MB. As sorted lines the same data
  answers in 0.36s. The lookup is `look` (binary search) plus an exact `awk` filter — `look` alone
  prefix-matches (`bet` returns `beta`), `awk` alone is a 26s full scan. Not `grep`, because *which*
  grep is on `PATH` decides the answer: 0.15s under ugrep against 8.3s under BSD `/usr/bin/grep`. The
  `LC_ALL=C sort` here is a contract with that binary search, asserted by the suite rather than left
  to review, because a collation disagreement returns nothing and reads exactly like "never called".

## What's NOT portable (per-machine, regenerated fresh each time)

- The Obsidian Local REST API plugin's self-signed cert + API key — each install generates its own.
  `setup-obsidian-mcp.sh` extracts these *after* you've installed the plugin; it does not carry them
  over from another machine.
- The `obsidian` MCP server registration in `~/.claude.json` (contains the bearer token —
  machine-local, not meant to be copied or committed).
- `NODE_EXTRA_CA_CERTS` in `~/.claude/settings.json` (the path is machine-specific anyway).

## New machine setup

```sh
git clone <this repo> ~/synapse   # or copy the folder over
cd ~/synapse
./setup.sh
```

`setup.sh` installs the portable tooling into `~/.claude/`, merges hook entries into
`~/.claude/settings.json` (idempotent — safe to re-run, does not clobber unrelated settings), and
prints the manual steps below.

1. Install Obsidian, open (or create) your Vault.
2. **Settings → Community plugins → Browse**, install + enable:
   - **Local REST API with MCP** (required — the actual bridge)
   - **Headless Mode** (optional but recommended — lets Obsidian run as a background daemon with no
     visible window; enable "Start headless" in its settings)
   - **Iconic** (optional — folder/file icons)
3. Run:
   ```sh
   ./setup-obsidian-mcp.sh /path/to/your/vault
   ```
   This extracts the plugin's generated cert + API key, wires `NODE_EXTRA_CA_CERTS`, and registers the
   `obsidian` MCP server at user scope (available from any project, any directory). Safe to re-run if
   you ever reinstall the plugin — new cert and key each time.
4. Edit `~/.claude/synapse.conf`: set `OBSIDIAN_VAULT_DIR` to the Vault path.
5. (Recommended) Add Obsidian to macOS login items so it is always running:
   ```sh
   osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Obsidian.app", hidden:false}'
   ```
6. Restart Claude Code.

`setup.sh` is safe to re-run at any time. It migrates config filenames it recognises, rewrites hook
paths in `settings.json` rather than adding a second copy, and reports any file under `~/.claude/` that
it no longer installs, so nothing is left running that the docs stop describing.

## Testing

```sh
brew install bats-core parallel          # if not already installed
bats --jobs "$(getconf _NPROCESSORS_ONLN)" tests/
```

`--jobs` needs GNU `parallel` on `PATH`; without it `bats` falls back to running serially, which is
correct but takes about three times as long (roughly 4.5 minutes against 1.5 here). The speedup comes
mostly from parallelising *within* each file rather than just across them — `synapse-write-node.bats`
alone is a quarter of the total, so across-files-only parallelism would leave it as the critical path.

This is safe because the tests share nothing: `common_setup` gives every single test its own `mktemp`
directory as `$HOME`, with its own scratch git repo and Vault inside it, and `common_teardown` removes
it. There is no `setup_file`, no fixed port, and no writes to the checkout — the two tests that read it
copy into scratch first. Keep it that way: **a test that reaches for state outside its own `$TEST_HOME`
is a test that will fail intermittently under `--jobs`, and intermittently is the expensive way to find
out.** The one sanctioned exception is `$REAL_HOME`, for caches that genuinely cannot be faked
(puppeteer's Chromium, npm's package cache), and it is read-mostly by the two diagram-rendering tests.

The same suite runs in CI on every push and pull request, on **Linux** (`.github/workflows/tests.yml`).
Both platforms do need covering — the two shells disagree in ways that pass silently on one of them,
BSD versus GNU `sed -i`, and macOS `mktemp` ignoring `TMPDIR` unless given an explicit template — but
macOS is covered by development itself, since the suite is written and run there. Linux is the half
nobody exercises by hand, so it is the half CI is spent on.

Covers `setup.sh` (idempotent install and merge into a scratch `$HOME`),
`synapse-session-start.sh` (index injection, the Graph pointer check, and the other-namespaces
catalogue — pure git and filesystem, no network), `synapse-staleness.sh` (Tier 1 flagging plus the
correction nudge, with `tests/fixtures/fake-bin/curl` stubbing out the Obsidian Local REST API so no
real Vault or plugin is needed), `synapse-tags.sh` (registry lookup, exit-code contract, and
clone/registration idempotency, with `tests/fixtures/fake-bin/{tree-sitter,git}` stubbing out the real
CLI and grammar cloning so no network access or tree-sitter install is needed), `synapse-tags-cache.sh`
and `synapse-query.sh symbol` (cold tagging, no-op on an unchanged re-run, single-file re-tag on a hash
change, unsupported-file caching so it's never silently retried, and the writer-side wiring that
populates the cache as a byproduct — same fake `tree-sitter`/`git` stubs), `synapse-build-refs.sh` and
`synapse-query.sh callers` (tag-line parsing including the space-padded name column that silently
answers nothing untrimmed, unsupported files excluded and counted, exact-not-prefix matching, regex
metacharacters in a name matched literally, a missing index exiting 1 rather than passing for "never
called", the no-vault/no-namespace independence that is the point of dispatching it early, and the
`look` fast path asserted equal to a full scan across mixed-case and punctuation-leading names —
against hand-written caches, since the tag line is exactly what is under test), `synapse-vocab.sh` (word
splitting, stopwording, group keying, per-run warning dedup and the empty-result contract, with the
fake `tree-sitter` emitting the symbols a fixture authored as `symbol:` lines so a vocabulary
assertion is about the reduction rather than about the stub), `synapse-gate.sh` (the flag boundary
pinned in both directions, document frequency counted across clusters rather than within one, and
the threshold's floor and scaling — against hand-written vocabulary tables, since what the gate
decides is separable from how the counts were obtained), `synapse-rank.sh` (size normalisation
asserted in both directions, definitions distinguished from references, the module constraint on
the consumer hop, and the summary/crux pool split including the `Latest.java` boundary), and the five node-building
scripts both individually and end-to-end through `tests/synapse-pipeline.bats`, which runs the whole
four-step build against a throwaway repo and reads the result back through `synapse-query.sh`.

`sources_digest` is recomputed independently in Python rather than by reusing a script's own formula,
so a drift between the writer and the verifier fails a test instead of silently agreeing with itself.
Every test runs against a throwaway `$HOME`, git repo and Vault created in `tests/test_helper.bash` —
nothing here touches your real `~/.claude` or Vault.

Also covered: the two generated artefacts, both verified by running their generator's `--check` mode, so
an edit that was never regenerated fails a test instead of shipping something confidently wrong.
`docs/scripts.md` comes from each script's header block via `docs/generate-scripts-reference.sh`. The
diagrams under `docs/diagrams/` are Mermaid sources rendered to PNG by `docs/generate-diagrams.sh`,
which records each source's hash so it can tell a stale render from a current one — it hashes the
`.mmd` rather than comparing PNG bytes, because mermaid-cli output is not byte-reproducible across
versions, fonts or platforms.

Not covered: `claude/commands/synapse-init.md`, `claude/commands/synapse-rebuild.md` and
`claude/skills/synapse-node/SKILL.md` are natural-language procedures Claude follows, not code —
there is nothing for a test framework to execute. That split is deliberate rather than a gap: those
documents hold the judgment (what the nodes are, what their prose says), and everything they delegate
to a script is what the suite covers. If a step in either can be tested, it belongs in a script
instead.

## Dependencies

`jq`, `bats-core` (tests only), the `claude` CLI. Optional: `tree-sitter` CLI plus a C compiler for
the Graph's tree-sitter acceleration (`synapse-tags.sh`), GNU `parallel` for `bats --jobs`, and Node
(for `npx`) to re-render the diagrams — everything degrades gracefully if any of them is missing, so
none is a hard requirement.

## License

MIT — see [LICENSE](LICENSE).
