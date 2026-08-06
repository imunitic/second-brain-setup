#!/bin/bash
# Removes Synapse namespaces whose branch was deleted upstream, and reports the
# ones it cannot decide about. The only destructive tool in Synapse, which is why
# it is a command you run rather than a hook that fires: these are notes in a
# permanent vault, and the system should not delete them on inference.
#
# Usage: synapse-graph-clean.sh [--dry-run]
#        synapse-graph-clean.sh --help
#
#   --dry-run  report what would be removed, delete nothing.
#
# Operates on the repo containing $PWD, across every branch's namespace for it --
# not just the branch checked out now.
#
# What it does with each `synapse/{repo}@{branch}/` namespace:
#
#   remove  the branch had an upstream and it is gone -- merged and deleted, the
#           case this exists for. `git branch -vv` shows it as `[origin/x: gone]`.
#   report  the branch is absent locally and no upstream can be confirmed. That
#           covers a never-pushed branch deleted by hand, and a branch whose
#           config went with it, which are indistinguishable after the fact.
#           Reported for a human to remove, never deleted here.
#   keep    anything else, including a branch that was never pushed and still
#           exists -- work in progress, whose namespace is in active use.
#
# A `git fetch --prune` runs first unless --dry-run: without it a deleted branch
# still has a local remote-tracking ref, every namespace looks alive, and the
# command silently does nothing.
#
# In a repo with no remote there is no upstream to consult at all, so the test
# falls back to whether the local branch still exists. Without that fallback the
# first run in a remoteless repo would classify every namespace as deleted
# upstream and wipe the lot.
#
# Deletion is on-disk rather than over the REST API, which would need one call
# per note. The vault's own git history (see synapse-db-sync.sh) is the undo.
#
# Exit codes:
#   0 - ran (removed something, or found nothing to remove)
#   1 - could not run (no vault, not in a git repo, missing dependency)
#   2 - usage error
set -uo pipefail

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

DRY_RUN=false
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage 0 ;;
    *)         usage ;;
esac

CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && source "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "synapse-graph-clean: no vault" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-graph-clean: git required" >&2; exit 1; }

REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || { echo "synapse-graph-clean: not inside a git repo" >&2; exit 1; }

# shellcheck source=/dev/null
. "$HOME/.claude/bin/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-graph-clean: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }

REPO="$(synapse_repo_name "$REPO_ROOT")"
[ -n "$REPO" ] || { echo "synapse-graph-clean: could not determine the repo name" >&2; exit 1; }

# Whether this repo has any remote at all decides which test applies below. Note
# synapse_remote falls back to the repo root path, so it is never empty -- ask
# git directly instead.
HAS_REMOTE=false
[ -n "$(git -C "$REPO_ROOT" remote 2>/dev/null | head -1 || true)" ] && HAS_REMOTE=true

if [ "$HAS_REMOTE" = true ] && [ "$DRY_RUN" = false ]; then
    # Failure is not fatal: offline or behind a VPN, the prune simply does not
    # happen, every namespace then looks alive, and nothing is removed. Erring
    # toward keeping notes is the right direction for the one destructive tool.
    git -C "$REPO_ROOT" fetch --prune --quiet 2>/dev/null \
        || echo "synapse-graph-clean: fetch failed -- deciding from local refs, which may be stale" >&2
fi

removed=0
reported=0
shopt -s nullglob
for ns_dir in "$VAULT/synapse/$REPO"@*; do
    [ -d "$ns_dir" ] || continue
    ns="$(basename "$ns_dir")"

    # The branch comes from the namespace's own `branch:` field, never from the
    # directory name: the name has `/` and other filename-hostile characters
    # translated to `-`, and that is not reversible -- `feature-CORE-1` could be
    # `feature/CORE-1` or a branch literally named `feature-CORE-1`. A namespace
    # with no readable field cannot be judged, so it is reported, not removed.
    branch=""
    [ -f "$ns_dir/Index.md" ] && branch="$(grep -m1 '^branch:' "$ns_dir/Index.md" 2>/dev/null \
        | sed -e 's/^branch: *//' -e 's/^"//' -e 's/"$//' || true)"
    if [ -z "$branch" ]; then
        printf 'report\t%s\tno branch field -- cannot tell which branch it describes\n' "$ns"
        reported=$((reported + 1))
        continue
    fi

    local_exists=false
    git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch" && local_exists=true

    if [ "$HAS_REMOTE" = false ]; then
        # No upstream can exist, so local existence is the whole question.
        if [ "$local_exists" = true ]; then
            continue
        fi
        printf 'report\t%s\tbranch %s is gone and the repo has no remote\n' "$ns" "$branch"
        reported=$((reported + 1))
        continue
    fi

    # Was an upstream configured for this branch, and has it gone? Read from
    # config plus the remote-tracking ref rather than `@{upstream}`, which stops
    # resolving once the ref is pruned and so cannot distinguish "never had one".
    upstream_remote="$(git -C "$REPO_ROOT" config --get "branch.$branch.remote" 2>/dev/null || true)"
    upstream_merge="$(git -C "$REPO_ROOT" config --get "branch.$branch.merge" 2>/dev/null || true)"
    if [ -n "$upstream_remote" ] && [ -n "$upstream_merge" ]; then
        upstream_branch="${upstream_merge#refs/heads/}"
        if git -C "$REPO_ROOT" show-ref --verify --quiet \
                "refs/remotes/$upstream_remote/$upstream_branch"; then
            continue   # still on the remote: alive
        fi
        # Configured and gone. This is the case the command exists for.
        if [ "$DRY_RUN" = true ]; then
            printf 'would-remove\t%s\tupstream %s/%s is gone\n' "$ns" "$upstream_remote" "$upstream_branch"
        else
            # Belt and braces before an rm -rf: only ever inside the vault's
            # synapse/ directory, and only a directory whose name we just matched.
            case "$ns_dir" in
                "$VAULT/synapse/"*) rm -rf "$ns_dir" ;;
                *) echo "synapse-graph-clean: refusing to remove $ns_dir" >&2; continue ;;
            esac
            printf 'removed\t%s\tupstream %s/%s is gone\n' "$ns" "$upstream_remote" "$upstream_branch"
        fi
        removed=$((removed + 1))
        continue
    fi

    # No upstream configured. Either never pushed, or the config went with the
    # branch -- indistinguishable now, so this is reported rather than removed.
    if [ "$local_exists" = true ]; then
        continue   # never pushed and still here: active work
    fi
    printf 'report\t%s\tbranch %s is absent locally and had no upstream configured\n' "$ns" "$branch"
    reported=$((reported + 1))
done

if [ "$removed" -eq 0 ] && [ "$reported" -eq 0 ]; then
    echo "nothing to clean"
fi
exit 0
