# Synapse

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

> **Upgrading from before the rename?** Just re-run `./setup.sh`. It moves
> `second-brain.conf`/`second-brain-projects.conf` to their `synapse-` names keeping your contents,
> rewrites the `settings.json` hook paths (and collapses any duplicate that creates, since a duplicated
> entry fires twice), and names the leftover files that are safe to delete. Every script also reads the
> old config name as a fallback, so scripts updated ahead of `setup.sh` keep working.

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
  by re-pointing, no reading) from *changed* (a claim to re-check). None of them ever pull. `body`
  prints a node's fenced prose, `sources` its file list filtered/counted/grouped by module, `field`
  one frontmatter scalar. A script rather than direct reads because a hub node's `sources` is ~38k
  tokens and `_index.json` ~350k — everything a script reads internally is free, only its stdout
  costs tokens.
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

If you are upgrading an install that predates the `sb-*` rename (formerly
`obsidian-note`/`obsidian-design-note`/`obsidian-task-note`/`obsidian-task`) or the removal of the
org-roam backend, re-running `setup.sh` flags any stale files left under `~/.claude/` so you can remove
them by hand.

## Testing

```sh
brew install bats-core   # if not already installed
bats tests/
```

Covers `setup.sh` (idempotent install and merge into a scratch `$HOME`),
`synapse-session-start.sh` (index injection, the Graph pointer check, and the other-namespaces
catalogue — pure git and filesystem, no network), `synapse-staleness.sh` (Tier 1 flagging plus the
correction nudge, with `tests/fixtures/fake-bin/curl` stubbing out the Obsidian Local REST API so no
real Vault or plugin is needed), `synapse-tags.sh` (registry lookup, exit-code contract, and
clone/registration idempotency, with `tests/fixtures/fake-bin/{tree-sitter,git}` stubbing out the real
CLI and grammar cloning so no network access or tree-sitter install is needed), and the five
node-building scripts both individually and end-to-end through `tests/synapse-pipeline.bats`, which
runs the whole four-step build against a throwaway repo and reads the result back through
`synapse-query.sh`.

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
the Graph's tree-sitter acceleration (`synapse-tags.sh`) — everything degrades gracefully to
full-read behaviour if either is missing, so neither is a hard requirement.
