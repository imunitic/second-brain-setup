# second-brain-setup

Portable packaging of the Obsidian-backed second-brain tooling built for Claude Code. Covers the
*tooling* only — not your actual notes/vault content, which is a separate sync concern (git,
Obsidian Sync, iCloud, manual copy — your call).

## What's in here (fully portable, no secrets)

- `claude/CLAUDE.md` — the global memory-system instructions.
- `claude/second-brain.conf.template` — path config (edit `OBSIDIAN_VAULT_DIR` per machine).
- `claude/hooks/second-brain-*.sh` — SessionStart index injection (also does the Synapse pointer
  check, see below), a turn-count-based Stop hook that forces a "worth capturing?" check-in every
  25 turns, and a db-sync hook that commits vault changes to the vault's own local git repo, if one
  exists.
- `claude/commands/sb-note.md` — note-creation command (bare/`--task`/`--list`/`--search` modes).
- `claude/commands/sb-design-note.md`, `claude/commands/sb-task-note.md` — a personal
  design-discussion → compiled-checklist pipeline that lives in the vault (`designs/`,
  `projects/`) instead of a repo's gitignored `docs/notes/`, so it's cross-project by default.
  Task-note creation and status tracking delegate to `sb-note.md --task` and `skills/sb-task/`
  above, not a separate mechanism.
- `claude/skills/sb-task/` — proactive task-status tracking skill.
- **Synapse** — a per-repo semantic code graph hosted in the vault under `synapse/{repo-name}/`,
  so Claude Code doesn't re-explore a codebase from scratch every session. Dormant until
  `/synapse-init` is run in a repo.
  - `claude/commands/synapse-init.md` — first-time build (an orientation pass, then clustering into a
    `manifest.tsv`, then node notes plus the two derived projections) and the manual
    `_unassigned`-sweep fallback for an already-initialized, otherwise-dormant repo. The division it
    enforces: deciding *what the nodes are* and writing their prose is the model's; enumerating,
    hashing, digesting and writing is the scripts'. `manifest.tsv` (`title <TAB> include-ERE <TAB>
    exclude-ERE`) is the seam, which is why coverage comes out as a printed number rather than a
    claim.
  - `claude/hooks/synapse-staleness.sh` — `PostToolUse` (`Write|Edit|MultiEdit`) Tier 1: flags
    edited files' nodes `stale` (or queues a brand-new file into `_unassigned`) via the Local REST
    API directly, no MCP round-trip.
  - `claude/skills/synapse-node/` — Tier 2: the lazy staleness check + regeneration + unassigned
    sweep Claude runs itself whenever a node's body is actually read, not a hook.
  - `claude/bin/synapse-query.sh` — read-only queries against a graph, printing only what was
    asked for. `stale` is the Tier 2 check (one `git hash-object` fork plus one GET per node,
    comparing each node's `sources_digest` against a recomputed one, printing only stale titles with
    a reason). `body` prints a node's fenced prose, `sources` its file list filtered/counted/grouped
    by module, `field` one frontmatter scalar. A script rather than direct reads because a hub node's
    `sources` is ~38k tokens and `_index.json` ~350k — everything a script reads internally is free,
    only its stdout costs tokens.
  - `claude/bin/synapse-build-lists.sh` — enumerates tracked files (dropping binaries, lockfiles,
    minified output and submodule gitlinks) and expands `manifest.tsv` into one path list per node,
    printing `enumerated/covered/unassigned` so a bad pattern is a number rather than a silent gap.
    Works out of `$SYNAPSE_WORK_DIR`, default `~/.claude/synapse-work/{repo-name}/` — never the repo,
    since these scripts run from inside it.
  - `claude/bin/synapse-write-node.sh` — writes one node: hashes every source, computes
    `sources_digest`, records the baseline `commit`, builds the aggregated `## Sources` mirror, and
    PUTs it, re-emitting everything after the closing fence verbatim so `## Notes` survives. Refuses
    to write into a namespace whose `remote` belongs to a different repo. The caller supplies only
    prose: the "never a context read" rule is symmetric, and a hub node's `sources` can no more be
    emitted into a tool call than read into a window.
  - `claude/bin/synapse-push-nodes.sh` — loops the writer over every node that has both a path list
    and an authored `b-NN.md`, taking each node's one-line `summary` from that file's frontmatter.
  - `claude/bin/synapse-build-index.sh` — builds `_index.json`, the reverse index the Tier 1 hook
    reads (source path → owning node filenames, plus `_unassigned`).
  - `claude/bin/synapse-build-project-index.sh` — builds `Index.md`, reading each bullet's headline
    back from that node's own `summary` field, so the map cannot describe a node as it used to be.
  - `claude/bin/synapse-tags.sh` — optional tree-sitter acceleration for clustering/regeneration/the
    `_unassigned` sweep: looks up a file's extension in a self-populating grammar registry
    (`~/.claude/synapse-grammars.conf`), clones/builds a native grammar on first need, and prints
    `tree-sitter tags` output (definitions + name-based call references). Fails soft on any missing
    piece (`tree-sitter`, a C compiler, an unsupported/undiscovered language) — every caller falls
    back to reading the file directly, exactly as if this script didn't exist.

## What's NOT portable (per-machine, regenerated fresh each time)

- The Obsidian Local REST API plugin's self-signed cert + API key — each
  install generates its own. `setup-obsidian-mcp.sh` extracts these
  *after* you've installed the plugin, it doesn't carry them over from
  another machine.
- The `obsidian` MCP server registration in `~/.claude.json` (contains the
  bearer token — machine-local, not meant to be copied/committed).
- `NODE_EXTRA_CA_CERTS` in `~/.claude/settings.json` (path is
  machine-specific anyway).

## New machine setup

```sh
git clone <this repo> ~/second-brain-setup   # or copy the folder over
cd ~/second-brain-setup
./setup.sh
```

`setup.sh` installs the portable tooling into `~/.claude/`, merges hook
entries into `~/.claude/settings.json` (idempotent — safe to re-run,
doesn't clobber unrelated settings), and prints the manual steps below.

1. Install Obsidian, open (or create) your vault.
2. **Settings → Community plugins → Browse**, install + enable:
   - **Local REST API with MCP** (required — the actual bridge)
   - **Headless Mode** (optional but recommended — lets Obsidian run as a
     background daemon with no visible window; enable "Start headless" in
     its settings)
   - **Iconic** (optional — folder/file icons)
3. Run:
   ```sh
   ./setup-obsidian-mcp.sh /path/to/your/vault
   ```
   This extracts the plugin's generated cert + API key, wires
   `NODE_EXTRA_CA_CERTS`, and registers the `obsidian` MCP server at user
   scope (available from any project, any directory). Safe to re-run if
   you ever reinstall the plugin (new cert/key each time).
4. Edit `~/.claude/second-brain.conf`: set `OBSIDIAN_VAULT_DIR` to the
   vault path.
5. (Recommended) Add Obsidian to macOS login items so it's always running:
   ```sh
   osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Obsidian.app", hidden:false}'
   ```
6. Restart Claude Code.

If you're upgrading an existing install that predates the `sb-*` rename (formerly
`obsidian-note`/`obsidian-design-note`/`obsidian-task-note`/`obsidian-task`) or the removal of the
org-roam backend, re-running `setup.sh` will flag any stale files left over from the old names/skill
under `~/.claude/` so you can remove them by hand.

## Testing

```sh
brew install bats-core   # if not already installed
bats tests/
```

Covers `setup.sh` (idempotent install/merge into a scratch `$HOME`),
`second-brain-session-start.sh` (index injection, the Synapse pointer
check, and the other-namespaces catalogue — pure git/filesystem, no
network), `synapse-staleness.sh`
(Tier 1 staleness flagging, with `tests/fixtures/fake-bin/curl` stubbing
out the Obsidian Local REST API so no real vault or plugin is needed),
`synapse-tags.sh` (registry lookup, exit-code contract, and
clone/registration idempotency, with `tests/fixtures/fake-bin/{tree-sitter,git}`
stubbing out the real CLI and grammar cloning so no network access or
tree-sitter install is needed), and the five node-building scripts
(`synapse-build-lists.sh`, `synapse-write-node.sh`, `synapse-push-nodes.sh`,
`synapse-build-index.sh`, `synapse-build-project-index.sh`) both individually
and end-to-end through `tests/synapse-pipeline.bats`, which runs the whole
four-step build against a throwaway repo and reads the result back through
`synapse-query.sh`. `sources_digest` is recomputed independently in Python
rather than by reusing a script's own formula, so a drift between the writer
and the verifier fails a test instead of silently agreeing with itself. Every
test runs against a throwaway `$HOME`/git repo/vault created in
`tests/test_helper.bash` — nothing here touches your real `~/.claude` or vault.

Not covered by these tests: `claude/commands/synapse-init.md` and
`claude/skills/synapse-node/SKILL.md` are natural-language procedures
Claude follows, not code — there's nothing for a test framework to
execute there. That split is deliberate rather than a gap: those two
documents hold the judgment (what the nodes are, what their prose says),
and everything they delegate to a script is what the suite covers. If a
step in either can be tested, it belongs in a script instead.

## Dependencies

`jq`, `bats-core` (tests only), the `claude` CLI. Optional: `tree-sitter` CLI + a C compiler, for
Synapse's tree-sitter acceleration (`synapse-tags.sh`) — everything degrades gracefully to full-read
behavior if either is missing, so neither is a hard requirement.
