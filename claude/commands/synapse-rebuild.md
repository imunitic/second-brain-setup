---
name: synapse-rebuild
description: Manually bring a repo's Synapse namespace back in line after major drift — a branch switch, a long absence, or a large merge. Triages each drifted node into reseat / patch-from-diff / re-orient rather than rebuilding everything.
---

# Synapse Rebuild: Reconcile a Namespace After Major Drift

`/synapse-init` builds a namespace. The two staleness tiers and `synapse-query.sh drift` *detect*
that it has moved. This command is the deliberate, human-invoked repair for the case where enough has
moved that lazy per-read regeneration is the wrong instrument.

## When to run it

Manually, when you already expect major drift:

- **A branch switch**, especially onto an older release line. The graph was built against a different
  line, and a large fraction of nodes will be flagged at once.
- **A long absence** — weeks or months of other people's commits landed while you were elsewhere.
- **A large merge or rebase** landing in your checkout.
- **You wrote a lot of code by hand.** The plainest case and probably the most common: days of ordinary
  work in your own branch, in your own editor, with no model involved. Tier 1 only fires on
  `Write`/`Edit`/`MultiEdit` *in this session*, so none of it was flagged as it happened. `stale` will
  still catch content changes to files a node already claims — but it reports a rename as "gone", and a
  **newly added file it cannot see at all**, because a path in no node's `sources` has nothing to
  compare against. Real feature work adds files, so this is exactly where the graph goes quietly out of
  date. Same applies to anything else that bypasses the session: an IDE refactor (which produces both
  bad cases at once — renames *and* new paths), a `sed -i`, generated code that the build rewrote from a
  schema, a dependency bump, or a moved submodule pointer.

Do **not** run it after an ordinary pull. Tier 1 flags what this session edited, the `synapse-node`
skill regenerates a node lazily when its body is actually needed, and `synapse-query.sh drift` is the
cheap check that tells you whether anything more is warranted. This command exists for when the answer
is clearly yes.

**A large job is the expected outcome, not a warning sign.** On a monorepo with a hundred thousand
files and heavy traffic, most of the graph moving at once is simply what the situation looks like, and
forty nodes in *re-orient* is a normal shape for this command rather than a reason to hesitate. Nothing
invokes this automatically — a human typed it, knowing their own repo and why they are here. So report
the size, then **do the work**. Do not recommend against a rebuild on the grounds that it is expensive,
do not offer a reduced version of it unasked, and do not describe replacing the graph as destructive:
replacing it is the entire point. Volunteer a smaller option only where a *correctness* reason argues
for one, and even then do the full job if the human says so.

**One mechanical fact about branches, because it is not guessable.** A namespace is keyed by repo
*and branch* (`synapse/{repo}@{branch}/`), so each branch has its own or has none. A branch switch
therefore no longer invalidates anything: the graph you built on the mainline stays intact and keeps
describing the mainline, and the branch you switched to simply has no namespace until someone runs
`/synapse-init` there. That is an ordinary state, not a problem to fix.

So the massive-drift case this command exists for is now the *unusual* one rather than the norm. It
still happens — a branch can be checked out inside any worktree, and a long-lived branch gets rebased
onto a moved trunk, which leaves the recorded baseline off the current line exactly as a branch switch
used to. Read a "not an ancestor of HEAD" warning as "history moved under this graph", and reach for
this command when it does. What no longer happens is arriving here merely because you changed branch.

## Prerequisites

- The namespace must exist. If `synapse/{repo}@{branch}/Index.md` is absent, this is a first build — use
  `/synapse-init`.
- The work directory (`$SYNAPSE_WORK_DIR`, default `~/.claude/synapse-work/{repo}@{branch}/`) ideally
  holds the `manifest.tsv` from the original build. Without it, new paths cannot be classified as
  auto-claimable, and clustering decisions have to be re-derived — say so rather than proceeding as if
  nothing were missing. `synapse/{repo}@{branch}/_manifest.tsv` is the fallback copy.
- Read `synapse/{repo}@{branch}/_profile.txt` if it exists, before triaging anything. It records the
  aggregations that carried signal for this repo and the searches that came back empty.

## Procedure

### 1. Size the job before doing any of it

```sh
~/.claude/bin/synapse-query.sh drift
~/.claude/bin/synapse-query.sh grounding
```

Report what it says, in the human's terms, **before** touching anything: how far the baseline is from
HEAD (and whether it is an ancestor at all), how many nodes are flagged in each class, and how many
added paths need a decision. Silence means nothing to rebuild — say so and stop, including when the
repo is behind its upstream: drift prints that only alongside a finding, because an accurate graph
plus unpulled commits is nothing to repair yet.

Two answers change the plan:

- **"baseline … is not an ancestor of HEAD"** — a branch switch or a reset. The file-level diff is
  still exactly right (it compares trees, not history), but expect deletions to dominate: files that
  exist on the built line and simply are not here.
- **"no commit recorded"** or **"baseline … not in local history"** — those nodes cannot be diffed at
  all. They go straight to the *re-orient* class in step 3; there is no cheaper option for them.

### 2. Mechanical phase — always, and cheap

```sh
~/.claude/bin/synapse-build-lists.sh --reenumerate
```

`--reenumerate` matters here: without it an existing `all.txt` is reused, so a branch switch would be
invisible to enumeration. **Read the coverage report.** On a branch switch, per-node list sizes will
move a lot and some may reach zero.

- **A node whose list is now empty** means that subsystem does not exist on this branch. **Do not
  write it** — `synapse-write-node.sh` refuses an empty path list, and that refusal is correct. Report
  the node and leave it in place, untouched. **Never delete a node to tidy up a branch switch:**
  `## Notes` is human-authored, lives outside the generated fence, and is unrecoverable.
- **Unclaimed added paths** are a judgment call: widen an existing manifest line where a path belongs
  to a cluster that already exists, and leave a genuinely new subsystem for a new manifest line and
  its own node. Re-run `synapse-build-lists.sh` after editing the manifest, and check coverage again.

Then rebuild the reverse index so the hook and the read path agree with the new enumeration:

```sh
~/.claude/bin/synapse-build-index.sh
```

### 3. Triage each flagged node — reseat, patch, or re-orient

**Two shared references before triaging.** The node contract — frontmatter, the crux pointer,
`## Links`, `grounded_in` — is `~/.claude/synapse-reference/node-format.md`, the same one
`/synapse-init` and the `synapse-node` skill write against. For a node in the *re-orient* class,
whose premises have to be re-derived rather than patched,
`~/.claude/synapse-reference/orientation.md` is the technique for working out where meaning lives in
a tree, which is the same problem a first build faces.

**The principle: compute new prose from the diff, not by re-reading the node's sources.** A node
covering 15,000 files where 12 changed already has prose encoding the other 14,988. Re-reading it all
is the expensive mistake this command exists to avoid, and it also throws away hard-won findings the
diff has nothing to say about.

**Take the nodes that lost files first, and keep the full list of deleted paths in front of you for
every node after that.** A deletion in one node is routinely the other half of an addition in
another — a type moved from the binary into a library, a module promoted out of a `util`. Triaged in
drift's arbitrary order, the node that *gained* the file is patched first, with no way to know the
file came from anywhere, and the patch fills the gap with a guess. One cheap list, read once:

```sh
git diff --diff-filter=D --name-only -M <commit>..HEAD
```

**Size each node by changed lines, not by changed files.** Drift reports file counts because that is
what it can compute without a diff, but a file count saturates immediately in a repo of small
modules: a node of 9 files with 5 touched reads as 56% when the actual change is 199 lines out of
2,077, and every one of them a formatting or import edit. Get the real ratio before choosing:

```sh
git diff --numstat <commit>..HEAD -- $(tr '\n' ' ' < "$W/lists/NN.txt") \
  | awk '{a += $1; d += $2} END {print a + d}'
```

against the node's own line count, and use `synapse-query.sh sources "{Node}" --count` for the file
count drift's numbers are relative to. Then pick one of three strategies and **say which one you
picked and why**:

**Restore the crux directive before writing any node back.** `synapse-query.sh body` returns the
*expanded* crux — the fenced code the writer sliced — not the directive that produced it. Writing that
straight back stores a quote of a file as it looked at the old baseline, presented as if it were
current. So rebuild the directive from the pointer the writer recorded:

```sh
~/.claude/bin/synapse-query.sh field "{Node}" crux_path
~/.claude/bin/synapse-query.sh field "{Node}" crux_lines
```

and replace the fenced block with `<!-- crux: <crux_path> <crux_lines> -->` so it is cut from the
current file. One judgment goes with it: re-slicing the same range is only safe if that file did not
change. If it did, the line numbers may now point at something else entirely — treat the crux as
needing a fresh pointer, exactly as the prose needs a fresh sentence. A node with no `crux_path` had
`none`, and stays that way.

**The same applies to groundings, and forgetting them loses more.** `grounded_in` is frontmatter and
its directives are stripped from the body, so a recovered body contains none — write it back as-is and
the node's provenance is gone with no error. Recover the pointers per node:

```sh
~/.claude/bin/synapse-query.sh grounding "{Node}" --list   # path<TAB>lines
```

and re-emit a `<!-- grounded_in: <path> <lines> -->` for each. Run `synapse-query.sh grounding` before
triaging: it is cheaper than the diff and sharper than a churn ratio. A **`moved`** line hands you the
corrected range outright, no reading. A **`changed`** line points at evidence that no longer says what
the summary claims — which is a better reason to re-read a node than any percentage, because it names
the sentence at risk rather than the volume of change around it.

**Reseat** — renames only, no content change. No reading at all. Recover the existing prose with
`synapse-query.sh body "{Node}"`, drop its trailing `## Sources` block (the writer regenerates that),
re-enumerate so the list holds the new paths, and write it back. Repeating this is safe: the writer
trims the body's leading and trailing blank lines, so a reseat is idempotent rather than accreting
padding each time. The concept did not change; only paths moved. This also
works on a machine that never built the namespace, because the body came from the node itself rather
than from a work-dir file.

**Patch from the diff** — a small fraction of the node's *lines* changed (rule of thumb: under ~15%),
and the file its `crux` quotes still exists. Read three things and nothing else:

1. the current prose — `synapse-query.sh body "{Node}"`;
2. `git diff --name-status -M <commit>..HEAD` restricted to that node's paths, for *which* files moved;
3. hunks for a **bounded** selection of those files — always including any file the `crux` quotes.

Then amend only the sentences the diff contradicts, and keep everything else verbatim.

**A patch may say what the node now contains. It must not say where something came from** unless the
rename is in the diff it read. Provenance is the one claim a node-restricted diff structurally cannot
support: the other end of the move is in a different node's paths, so the diff shows an unexplained
new file, and the plausible local origin is an invention. `git`'s rename detection is not a
safety net here — a file that moved between modules and was rewritten on the way lands below the
similarity threshold and shows up as a delete in one node and an add in another even under
`-M --find-copies-harder`. Which is why deletions get read first, below.

**Re-orient** — a large fraction changed, the baseline is unusable, or there is a structural signal:
the `crux` file is gone or renamed, whole modules entered or left the node, or a package root changed
name. Here the prose's premises are suspect, so patching would preserve a claim that is no longer
true. Re-run this node's aggregations from `_profile.txt` (path-level, so cheap even on a hub node),
read the few load-bearing files the aggregations point at, and re-author as `/synapse-init` would.

**The diff must be projected as carefully as `sources` is.** `git diff` with hunks across a hub node's
paths over hundreds of commits runs to megabytes — the same constraint that makes `sources` unreadable
applies to the diff. So: `--name-status` for names, `--stat` to size it, and hunks only for a bounded
selection. Never pipe an unbounded `git diff <commit>..HEAD` into a context window.

### 4. Write each rebuilt node

```sh
~/.claude/bin/synapse-write-node.sh --title "{Node}" --summary "{one line}" \
   --paths "$W/lists/NN.txt" --body "$W/body.md"
```

It re-records `commit`, so this checkout becomes the node's new baseline — which is what makes the next
`drift` meaningful. **Re-check the one-line `summary`**: after a branch switch it can be wrong in kind,
not merely stale, if the subsystem's shape differs on this line.

### 5. Rebuild the projections and verify

```sh
~/.claude/bin/synapse-build-index.sh
~/.claude/bin/synapse-build-project-index.sh
~/.claude/bin/synapse-query.sh drift     # expect silence
~/.claude/bin/synapse-query.sh stale     # expect silence
~/.claude/bin/synapse-query.sh grounding # expect silence: re-pointed, not dropped
~/.claude/bin/synapse-query.sh links --check   # expect silence: no dangling targets
```

`links --check` covers what used to be a manual instruction here: a broken `[[wikilink]]` is a valid
link to a not-yet-existing note, so Obsidian renders it without complaint and nothing else in the
system notices. It now reports `Node<TAB>relation -> Target (no such node)` per dangling edge.

One check is still yours, because no command performs it: **every node file appears in `Index.md`**. An
unlisted node exists and is reachable by search, but is invisible to anyone reading the map.

### 6. Report what happened

Per node: the strategy chosen and why. Plus what was deliberately left alone — nodes drift did not
flag, and nodes whose sources vanished on this branch. A rebuild that silently re-authored forty nodes
is indistinguishable, from the outside, from one that did nothing.

## Guardrails

- **Never `pull`, `fetch --prune`, `rebase`, `reset` or `checkout`.** The human chose this checkout;
  this command describes and records it. Report how far behind the upstream ref is and stop there.
- **Never re-read a node's full sources to patch a small diff.** That is the specific waste this
  command is built to avoid.
- **Know what patching cannot fix.** It keeps every sentence the diff does not contradict, so a claim
  that was wrong when the node was *built* survives every future patch untouched — the diff has
  nothing to say about a statement that was never true. Patching is therefore only as good as the
  baseline prose, and a node's most likely error is not drift but an explanation invented at build
  time. The `crux` is no longer the exposure it was — `synapse-write-node.sh` slices it out of the
  file from a `<!-- crux: path start-end -->` directive, so it is verbatim by construction rather than
  by instruction. What remains unguarded is the prose. A sentence asserting a *mechanism* ("X is
  behind a mutex, which is why Y")
  deserves more suspicion than one asserting structure — if the diff touches its file at all, verify
  it rather than carrying it over.
- **Never write a node with an empty path list**, and never delete a node whose sources vanished — its
  `## Notes` is human-authored and outside the generated fence.
- **Never hand-write frontmatter or the `## Sources` mirror.** `synapse-write-node.sh` owns them; doing
  it by hand cannot scale to a hub node and silently drops `summary` and `commit`.
- **Never rebuild a node drift did not flag.** Regeneration has real cost and it is not free of risk —
  each rewrite is a chance to lose a good sentence.
- **Say when the graph now describes a different branch than it did before**, in the final report. That
  fact outlives the session, and the next reader has no other way to know.
