---
name: sync-github-forks
description: Use when the user asks to sync, update, refresh, or fast-forward personal GitHub forks, forked repos, remote forks, or a named fork from upstream with GitHub CLI.
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

1. Determine the scope and intent from the user's request: all personal forks, one owner, one repository, archived forks, a named branch, force sync, dry-run only, or actual execution.
2. Verify `gh` is installed and authenticated:

```bash
gh --version
gh auth status
```

3. In sandboxed environments, `gh` may not see the user's keyring or real network context. If `gh auth status` fails in the sandbox, retry outside the sandbox before reporting an authentication failure. If the user explicitly asks to use the real/local `gh`, run `gh` outside the sandbox.
4. Resolve named repositories before syncing:
   - If the user provides exact `OWNER/REPO`, use that value with `--repo`.
   - If the user gives a natural-language name such as "cc switch", list forks and match normalized names: lowercase and ignore spaces, hyphens, and underscores.
   - If exactly one fork clearly matches, use that `OWNER/REPO`.
   - If multiple forks are plausible, show the candidates and ask which one to sync.
5. If the user did not specify an owner, let the script use the authenticated GitHub user.
6. Run a dry-run first unless the user explicitly requested immediate broad execution:

```bash
scripts/sync_github_forks.sh --dry-run
```

7. Execute after the dry-run result identifies the intended target and the user's intent allows execution:

```bash
scripts/sync_github_forks.sh --execute
```

8. Report a short summary: synced or planned, failed, skipped, and the exact command to rerun if needed.

## If Prerequisites Are Missing

- If `gh --version` fails, stop and tell the user to install GitHub CLI before continuing.
- If `gh auth status` fails in a sandboxed environment, retry outside the sandbox before deciding authentication is invalid.
- If `gh auth status` fails outside the sandbox too, stop and ask the user to run:

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
- For natural-language repository names, resolve candidates with `gh repo list OWNER --fork --json nameWithOwner,name,parent` before choosing `--repo`.
- If natural-language matching returns multiple plausible repositories, ask the user to choose instead of guessing.
- Use `--owner OWNER` when the user wants forks owned by a specific user or organization.
- Use `--branch BRANCH` only when the user asks for a specific branch; otherwise sync default branches.
- Use `--include-archived` only when the user explicitly asks to include archived forks.
- Use `--force` only when the user explicitly asks for a force sync or hard reset style sync.
- If the user asks to update, sync, or refresh one named fork, treat that as permission to execute after a dry-run confirms the single intended repository.
- If the user asks to update, sync, or refresh all forks or another broad scope, run dry-run first and ask for approval unless the user explicitly requested immediate execution.
- If the user asks to run the skill without saying dry-run or execute and the scope is unclear, run `--dry-run`.

## Safety Rules

- Default to `--dry-run`; do not modify remote repositories unless the user requested execution.
- Do not pass `--force` unless the user explicitly asks for a hard reset style sync.
- Default to non-archived repositories. Use `--include-archived` only when the user explicitly asks for archived forks too.
- Prefer syncing default branches. Use `--branch` only when the user asks for a specific branch.
- If sandboxed `gh auth status` fails, retry outside the sandbox before asking the user to re-authenticate with `gh auth login`.
- Do not execute when natural-language repository matching is ambiguous.
- If a repository fails to sync, continue to the next repository and summarize failures at the end.

## Notes

- `gh repo sync OWNER/REPO` syncs a remote fork from its parent. Without `--force`, GitHub CLI uses a fast-forward update and fails rather than hard-resetting divergent work.
- This skill is for remote GitHub forks, not local working tree synchronization. For a single local clone, use normal `git fetch`, `git merge --ff-only`, or `gh repo sync` from that repository.
