---
name: sync-github-forks
description: Batch synchronize forked repositories owned by the authenticated GitHub user using GitHub CLI. Use when the user asks to sync, update, refresh, or fast-forward all personal GitHub forks, forked repos, or remote forks from their upstream parents.
---

# Sync GitHub Forks

## Overview

Use this skill to synchronize forked repositories owned by a GitHub user from their upstream parents through `gh` CLI. Prefer the bundled script so enumeration, dry-run behavior, and per-repository error handling stay consistent.

## Prerequisites

- No project `.env`, token file, or local clone configuration is required.
- `gh` must be installed and available on `PATH`.
- `gh` must be authenticated for `github.com`.
- The authenticated account must have permission to list and sync the target forks.

## Default Workflow

1. Determine the scope from the user's request: all personal forks, one owner, one repository, archived forks, a named branch, or force sync.
2. Verify `gh` is installed and authenticated:

```bash
gh --version
gh auth status
```

3. If the user did not specify an owner, let the script use the authenticated GitHub user.
4. Run a dry-run first unless the user explicitly requested immediate execution:

```bash
scripts/sync_github_forks.sh --dry-run
```

5. Execute only after the dry-run result looks correct and the user approves, or when the user already gave explicit approval:

```bash
scripts/sync_github_forks.sh --execute
```

6. Report a short summary: synced, failed, skipped, and the exact command to rerun if needed.

## If Prerequisites Are Missing

- If `gh --version` fails, stop and tell the user to install GitHub CLI before continuing.
- If `gh auth status` fails, stop and ask the user to run:

```bash
gh auth login -h github.com
```

- Do not ask the user for a GitHub token unless they explicitly want a non-interactive setup. Prefer `gh auth login`.

## Script Usage

`scripts/sync_github_forks.sh` uses `gh repo list` to find forked repositories and `gh repo sync` to update each fork from its parent.

Common commands:

```bash
# Preview all non-archived forks owned by the authenticated user.
scripts/sync_github_forks.sh --dry-run

# Sync all non-archived forks owned by the authenticated user.
scripts/sync_github_forks.sh --execute

# Sync forks owned by a specific user or organization.
scripts/sync_github_forks.sh --owner OWNER --execute

# Test one repository before syncing all forks.
scripts/sync_github_forks.sh --repo OWNER/REPO --execute

# Sync a named branch across matching forks.
scripts/sync_github_forks.sh --branch main --execute
```

## Decision Rules

- Use `--repo OWNER/REPO` when the user names one fork or asks to test the workflow on a single repository.
- Use `--owner OWNER` when the user wants forks owned by a specific user or organization.
- Use `--branch BRANCH` only when the user asks for a specific branch; otherwise sync default branches.
- Use `--include-archived` only when the user explicitly asks to include archived forks.
- Use `--force` only when the user explicitly asks for a force sync or hard reset style sync.
- If the user asks to run the skill without saying dry-run or execute, run `--dry-run`.

## Safety Rules

- Default to `--dry-run`; do not modify remote repositories unless the user requested execution.
- Do not pass `--force` unless the user explicitly asks for a hard reset style sync.
- Default to non-archived repositories. Use `--include-archived` only when the user explicitly asks for archived forks too.
- Prefer syncing default branches. Use `--branch` only when the user asks for a specific branch.
- If `gh auth status` fails, stop and ask the user to re-authenticate with `gh auth login`.
- If a repository fails to sync, continue to the next repository and summarize failures at the end.

## Notes

- `gh repo sync OWNER/REPO` syncs a remote fork from its parent. Without `--force`, GitHub CLI uses a fast-forward update and fails rather than hard-resetting divergent work.
- This skill is for remote GitHub forks, not local working tree synchronization. For a single local clone, use normal `git fetch`, `git merge --ff-only`, or `gh repo sync` from that repository.
