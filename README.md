# Synapse

[![tests](https://github.com/imunitic/synapse/actions/workflows/tests.yml/badge.svg)](https://github.com/imunitic/synapse/actions/workflows/tests.yml)

Memory for Claude Code: durable notes that outlive a session, and a per-repo code graph so a
codebase does not get re-explored from scratch every time. Three components, independent enough that
you can use one without the others:

- **Synapse Vault** — an Obsidian vault holding the notes: research, decisions, project logs, design
  discussions. Cross-project by default and searchable as ordinary Markdown.
- **Synapse Graph** — a per-repo semantic code graph, hosted *inside* the Vault under
  `synapse/{repo-name}/`, so it is stored and searched like any other note. Dormant until
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
  None of them ever pull. `body` prints a node's fenced prose, `sources` its file list
  filtered/counted/grouped by module, `field` one frontmatter scalar. A script rather than direct reads
  because a hub node's `sources` is ~38k tokens and `_index.json` ~350k — everything a script reads
  internally is free, only its stdout costs tokens.
- `claude/bin/synapse-build-lists.sh` — enumerates tracked files (dropping binaries, lockfiles,
  minified output and submodule gitlinks) and expands `manifest.tsv` into one path list per node,
  printing `enumerated/covered/unassigned` so a bad pattern is a number rather than a silent gap.
  Works out of `$SYNAPSE_WORK_DIR`, default `~/.claude/synapse-work/{repo-name}/` — never the repo,
  since these scripts run from inside it.
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
- `claude/bin/synapse-tags.sh` — optional tree-sitter acceleration for clustering, regeneration and
  the `_unassigned` sweep: looks up a file's extension in a self-populating grammar registry
  (`~/.claude/synapse-grammars.conf`), clones and builds a native grammar on first need, and prints
  `tree-sitter tags` output (definitions plus name-based call references). Fails soft on any missing
  piece (`tree-sitter`, a C compiler, an unsupported language) — every caller falls back to reading the
  file directly, exactly as if this script did not exist.
- `claude/bin/synapse-tags-cache.sh` — keeps `synapse/{project}/_tags_cache.json` (`path → {hash,
  tags}`) current for a set of files, piggybacked on the same per-file hash comparison node
  regeneration already performs rather than a separate staleness pass: unchanged paths are skipped,
  changed-or-missing ones are (re-)tagged in parallel via `xargs -P` (capped at the machine's core
  count), each worker writing its own result to a private temp file before one sequential merge writes
  the cache — never a worker writing the shared file directly. `synapse-write-node.sh` calls this as a
  byproduct of its own hashing; `synapse-query.sh symbol` calls it to lazily backfill whatever a node's
  cache hasn't reached yet. Disable entirely with `SYNAPSE_DISABLE_SYMBOL_CACHE`.

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

The same suite runs in CI on every push and pull request, on both Linux and macOS
(`.github/workflows/tests.yml`). Both platforms deliberately: the two shells disagree in ways that pass
silently on one of them — BSD versus GNU `sed -i`, and macOS `mktemp` ignoring `TMPDIR` unless given an
explicit template — so a single-platform run would keep finding out about the other one from a bug
report.

Covers `setup.sh` (idempotent install and merge into a scratch `$HOME`),
`synapse-session-start.sh` (index injection, the Graph pointer check, and the other-namespaces
catalogue — pure git and filesystem, no network), `synapse-staleness.sh` (Tier 1 flagging plus the
correction nudge, with `tests/fixtures/fake-bin/curl` stubbing out the Obsidian Local REST API so no
real Vault or plugin is needed), `synapse-tags.sh` (registry lookup, exit-code contract, and
clone/registration idempotency, with `tests/fixtures/fake-bin/{tree-sitter,git}` stubbing out the real
CLI and grammar cloning so no network access or tree-sitter install is needed), `synapse-tags-cache.sh`
and `synapse-query.sh symbol` (cold tagging, no-op on an unchanged re-run, single-file re-tag on a hash
change, unsupported-file caching so it's never silently retried, and the writer-side wiring that
populates the cache as a byproduct — same fake `tree-sitter`/`git` stubs), and the five node-building
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
