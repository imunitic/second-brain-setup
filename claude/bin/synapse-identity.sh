#!/bin/bash
# Sourced by every component that has to name a Synapse namespace. One copy on
# purpose: synapse-staleness.sh already carried a comment warning that a
# divergent resolution chain makes one component refuse where another proceeds,
# and that warning applied to five inline copies of the same logic. This is that
# chain, once.
#
# A namespace is keyed by repo AND branch -- `synapse/{repo}@{branch}/` -- so the
# graph describes one tree rather than every branch at once. Worktrees need no
# handling of their own: git refuses to check out one branch in two worktrees of
# a repository (the main checkout included), so a branch already names at most
# one checkout. That is why there is no `.git`-file parsing here, no `gitdir:` or
# `commondir` walking, and no worktree-versus-submodule discrimination -- the
# whole question reduces to which branch is checked out.
#
# Usage (sourced, never executed):
#   . "$HOME/.claude/bin/synapse-identity.sh"
#   REMOTE="$(synapse_remote "$REPO_ROOT")"           # identity, unchanged chain
#   NS="$(synapse_namespace "$REPO_ROOT")" || ...     # "{repo}@{branch}"
#
# Deliberately does NOT `set -euo pipefail`: a sourced file that sets shell
# options silently rewrites its caller's error handling. Every git call below is
# guarded instead, so these stay safe under a caller that does set them -- which
# all the hooks do.

# The remote URL used as identity, resolved origin -> first listed remote -> the
# repo root path. Unchanged from what every component already did; a repo with no
# remote at all still gets a stable value, and refusing those outright would turn
# a working local-only project into an error.
synapse_remote() { # synapse_remote <repo-root>
    local root="$1" remote first
    remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
    if [ -z "$remote" ]; then
        first="$(git -C "$root" remote 2>/dev/null | head -1 || true)"
        [ -n "$first" ] && remote="$(git -C "$root" remote get-url "$first" 2>/dev/null || true)"
    fi
    [ -n "$remote" ] || remote="$root"
    printf '%s' "$remote"
}

# The repo half of the key, taken from the REMOTE rather than the directory. A
# linked worktree's directory basename differs from its parent's, and that
# difference is exactly what must stop mattering -- deriving from the directory
# would put one repo's branches under two different names. Falls back to the
# toplevel basename only when there is no remote at all, in which case
# synapse_remote already returned that same path.
synapse_repo_name() { # synapse_repo_name <repo-root>
    local root="$1" remote name
    remote="$(synapse_remote "$root")"
    name="$(basename "$remote")"
    printf '%s' "${name%.git}"
}

# The branch half, sanitized for use as one directory name. Branch names legally
# contain `/` (feature/CORE-101490-...), which would silently create nesting, and
# git permits a few characters that are illegal in filenames elsewhere -- so the
# vault's own illegal set is translated too rather than trusting git's ref rules
# to be a filename whitelist.
#
# `symbolic-ref --short HEAD`, not `rev-parse --abbrev-ref HEAD`. Two reasons,
# both load-bearing rather than stylistic:
#
#   - On a detached HEAD, rev-parse returns the literal string "HEAD" -- a
#     plausible-looking value that is identical across every detached checkout
#     everywhere, so it would silently become a shared key. symbolic-ref simply
#     fails, which needs no special-casing to get right.
#   - Before the first commit the branch exists but points at nothing, and
#     rev-parse fails ("ambiguous argument 'HEAD'") while symbolic-ref reports
#     the unborn branch correctly. A repo mid-`/synapse-init` on a fresh branch
#     is a real case, and it should resolve rather than error.
synapse_branch() { # synapse_branch <repo-root>
    local root="$1" branch
    branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -z "$branch" ]; then
        echo "synapse: detached HEAD -- a namespace is keyed by branch, so there is none here" >&2
        return 1
    fi
    printf '%s' "$(printf '%s' "$branch" | tr '/:*?"<>|' '-')"
}

# The namespace directory name: "{repo}@{branch}". `@` rather than `:` because
# `:` is illegal in a vault filename and renders as `/` in macOS Finder. Flat
# rather than nested, so every caller keeps building `synapse/$NS/...` with a
# single variable segment.
synapse_namespace() { # synapse_namespace <repo-root>
    local root="$1" repo branch
    repo="$(synapse_repo_name "$root")"
    branch="$(synapse_branch "$root")" || return 1
    [ -n "$repo" ] || return 1
    printf '%s@%s' "$repo" "$branch"
}
