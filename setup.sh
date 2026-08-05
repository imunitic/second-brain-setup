#!/bin/bash
# Installs the portable Synapse tooling (CLAUDE.md, hooks, commands, skills,
# scripts) into ~/.claude on this machine. Merges into existing
# settings.json rather than overwriting it. Does NOT touch Obsidian
# itself, plugin installs, API keys/certs, or note content -- see
# setup-obsidian-mcp.sh and the README for those.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/claude"
DEST="$HOME/.claude"

command -v jq >/dev/null || { echo "jq is required. Install it first (e.g. brew install jq)." >&2; exit 1; }

mkdir -p "$DEST/hooks" "$DEST/commands" "$DEST/skills/synapse-task" "$DEST/skills/synapse-node" "$DEST/skills/synapse-query" "$DEST/bin"

echo "== CLAUDE.md =="
if [ -f "$DEST/CLAUDE.md" ] && ! diff -q "$SRC/CLAUDE.md" "$DEST/CLAUDE.md" >/dev/null 2>&1; then
  echo "  ~/.claude/CLAUDE.md already exists and differs -- not overwriting."
  echo "  Diff manually and merge: diff '$SRC/CLAUDE.md' '$DEST/CLAUDE.md'"
else
  cp "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"
  echo "  installed."
fi

# Migrate the pre-rename filenames before the install checks below, or an existing
# machine gets a fresh template alongside its real config and silently loses its
# vault path. A move rather than a copy: two files, one of them stale, is worse
# than either alone -- and the readers fall back to the old name only so that
# scripts updated ahead of this script keep working, not as a place to keep
# config permanently.
echo "== config filenames =="
for pair in "second-brain.conf:synapse.conf" "second-brain-projects.conf:synapse-projects.conf"; do
  old="${pair%%:*}"; new="${pair##*:}"
  if [ -f "$DEST/$old" ] && [ ! -f "$DEST/$new" ]; then
    mv "$DEST/$old" "$DEST/$new"
    echo "  renamed (project rename): $old -> $new"
  elif [ -f "$DEST/$old" ] && [ -f "$DEST/$new" ]; then
    echo "  WARNING both $old and $new exist -- $new is the one that is read."
    echo "  Merge anything you need out of $old, then delete it."
  fi
done

echo "== synapse.conf =="
if [ -f "$DEST/synapse.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse.conf"
else
  cp "$SRC/synapse.conf.template" "$DEST/synapse.conf"
  echo "  installed from template -- EDIT THIS FILE (paths are machine-specific): $DEST/synapse.conf"
fi

echo "== synapse-projects.conf =="
if [ -f "$DEST/synapse-projects.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse-projects.conf"
else
  cp "$SRC/synapse-projects.conf.template" "$DEST/synapse-projects.conf"
  echo "  installed from template -- machine-local, self-managed by /synapse-note: $DEST/synapse-projects.conf"
fi

echo "== synapse-module-boilerplate.conf =="
if [ -f "$DEST/synapse-module-boilerplate.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse-module-boilerplate.conf"
else
  cp "$SRC/synapse-module-boilerplate.conf.template" "$DEST/synapse-module-boilerplate.conf"
  echo "  installed from template -- edit to add your own ecosystem's src/ conventions: $DEST/synapse-module-boilerplate.conf"
fi

echo "== synapse-prompt-stopwords.conf =="
if [ -f "$DEST/synapse-prompt-stopwords.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse-prompt-stopwords.conf"
else
  cp "$SRC/synapse-prompt-stopwords.conf.template" "$DEST/synapse-prompt-stopwords.conf"
  echo "  installed from template -- edit to add another language's stopwords: $DEST/synapse-prompt-stopwords.conf"
fi

echo "== hooks/commands/skills =="
cp "$SRC/hooks/"*.sh "$DEST/hooks/"
chmod +x "$DEST/hooks/"*.sh
cp "$SRC/commands/"*.md "$DEST/commands/"
cp "$SRC/skills/synapse-task/SKILL.md" "$DEST/skills/synapse-task/SKILL.md"
cp "$SRC/skills/synapse-node/SKILL.md" "$DEST/skills/synapse-node/SKILL.md"
cp "$SRC/skills/synapse-query/SKILL.md" "$DEST/skills/synapse-query/SKILL.md"
# Glob rather than naming each script, matching how hooks/ is copied above --
# naming them individually meant a newly added script silently didn't install.
cp "$SRC/bin/"*.sh "$DEST/bin/"
chmod +x "$DEST/bin/"*.sh
echo "  installed."
if [ -d "$DEST/skills/obsidian-task" ] || [ -f "$DEST/bin/second-brain-switch" ] || ls "$DEST/commands/obsidian-"*.md >/dev/null 2>&1 || [ -d "$DEST/skills/org-task" ]; then
  echo "  NOTE: found stale files from before the sb- rename / org-roam removal --"
  echo "    $DEST/skills/obsidian-task/, $DEST/skills/org-task/, $DEST/bin/second-brain-switch,"
  echo "    $DEST/commands/obsidian-*.md are no longer installed by this script and are safe"
  echo "    to remove by hand."
fi
# The sb- -> synapse- rename. Worth its own louder warning than the note above,
# because these are not merely unused: a leftover commands/sb-note.md still
# registers as /sb-note, so the command list shows two of everything and only one
# is maintained. Claude Code discovers commands by filename, so nothing here can
# deduplicate them -- only deleting the old file can.
if ls "$DEST/commands/sb-"*.md >/dev/null 2>&1 || [ -d "$DEST/skills/sb-task" ]; then
  echo "  WARNING: found pre-rename copies of the renamed commands/skill:"
  ls "$DEST/commands/sb-"*.md 2>/dev/null | sed 's/^/    /'
  [ -d "$DEST/skills/sb-task" ] && echo "    $DEST/skills/sb-task/"
  echo "    They are no longer installed, but they still REGISTER -- you will see both"
  echo "    /sb-note and /synapse-note until you delete them. Remove them by hand."
fi
# The hook rename. Unlike the commands above these are now INERT -- the
# settings.json pass below rewrites every reference to the new names, so nothing
# invokes the old files. Still worth naming: an executable nobody calls is the
# kind of thing that gets resurrected by a hand-edited settings.json months later.
if ls "$DEST/hooks/second-brain-"*.sh >/dev/null 2>&1; then
  echo "  NOTE: pre-rename hook files are no longer referenced by settings.json:"
  ls "$DEST/hooks/second-brain-"*.sh 2>/dev/null | sed 's/^/    /'
  echo "    Safe to remove by hand."
fi
# This script copies in but never deletes, so a file removed from the source
# lingers in $DEST -- unreferenced but still executable, which is worse than
# absent because it silently keeps working after the docs stop mentioning it.
if [ -f "$DEST/bin/synapse-verify.sh" ]; then
  echo "  NOTE: $DEST/bin/synapse-verify.sh is stale -- it folded into"
  echo "    synapse-query.sh as the 'stale' subcommand. Safe to remove by hand."
fi

echo "== settings.json hook wiring =="
SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TMP="$(mktemp)"
jq '
  # Rewrite pre-rename hook paths BEFORE the add-if-missing logic below, which is
  # the whole difficulty of renaming a hook. settings.json references hooks by
  # path, and this script copies in without deleting -- so without this pass an
  # existing machine ends up with the old entry AND the new one, both pointing at
  # files that exist, and every hook fires twice: two index injections, two
  # nudges, two vault commits per write.
  #
  # Scoped to the hook arrays rather than walk(), so an unrelated `command`
  # elsewhere in settings.json (a statusLine, for instance) is never touched.
  def fixcmd:
    if type == "string" then
        gsub("second-brain-session-start\\.sh"; "synapse-session-start.sh")
      | gsub("second-brain-stop-nudge\\.sh";    "synapse-stop-nudge.sh")
      | gsub("second-brain-db-sync\\.sh";       "synapse-db-sync.sh")
    else . end;
  # Order-preserving dedupe: if a machine somehow already had both spellings, the
  # rewrite above makes them identical, and two identical entries fire twice.
  def dedupe: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  .hooks = ((.hooks // {}) | map_values(
      map(.hooks = ((.hooks // []) | map(.command |= fixcmd))) | dedupe)) |

  .hooks = (.hooks // {}) |
  .hooks.SessionStart = (.hooks.SessionStart // []) |
  .hooks.PostToolUse = (.hooks.PostToolUse // []) |
  .hooks.Stop = (.hooks.Stop // []) |
  .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // []) |
  (if any(.hooks.SessionStart[]?.hooks[]?; .command == "bash ~/.claude/hooks/synapse-session-start.sh")
   then . else .hooks.SessionStart += [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-session-start.sh"}]}] end) |
  (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == "bash ~/.claude/hooks/synapse-prompt-context.sh")
   then . else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-prompt-context.sh"}]}] end) |
  (if any(.hooks.PostToolUse[]?.hooks[]?; .command == "bash ~/.claude/hooks/synapse-db-sync.sh")
   then . else .hooks.PostToolUse += [{"matcher":"Write|Edit|mcp__obsidian__vault_(write|patch|append|delete|move)","hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-db-sync.sh"}]}] end) |
  (if any(.hooks.PostToolUse[]?.hooks[]?; .command == "bash ~/.claude/hooks/synapse-staleness.sh")
   then . else .hooks.PostToolUse += [{"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-staleness.sh"}]}] end) |
  (if any(.hooks.Stop[]?.hooks[]?; .command == "bash ~/.claude/hooks/synapse-stop-nudge.sh")
   then . else .hooks.Stop += [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-stop-nudge.sh"}]}] end)
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
echo "  merged (idempotent -- safe to re-run)."

cat <<'EOF'

== Done with the automatable part. Manual steps remaining: ==

1. Edit ~/.claude/synapse.conf -- set OBSIDIAN_VAULT_DIR for this
   machine.
2. Install Obsidian.app, open your vault.
3. Settings -> Community plugins -> Browse -> install + enable:
   "Local REST API with MCP", "Headless Mode", "Iconic" (optional).
4. Run: ./setup-obsidian-mcp.sh <path-to-vault>
   (extracts the plugin's generated cert + API key, registers the
   MCP server, wires up NODE_EXTRA_CA_CERTS -- all automatic once
   the plugin is installed and has generated its data.json).
5. Optionally add Obsidian to login items and enable "Start headless"
   in the Headless Mode plugin settings, so it runs like a background
   daemon (see README).
6. Restart Claude Code so the new hooks/settings/MCP registration
   actually take effect for the running session.
EOF
