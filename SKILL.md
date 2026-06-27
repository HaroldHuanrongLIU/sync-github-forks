---
name: sync-github-forks
description: Use when the user asks to sync, update, refresh, or fast-forward personal GitHub forks, forked repos, remote forks, or a named fork from upstream with GitHub CLI.
---

# Sync GitHub Forks

## Overview

Use this skill to check and synchronize forked repositories owned by a GitHub user from their upstream parents through `gh` CLI. Prefer the bundled script so enumeration, status comparison, dry-run behavior, branch mismatch handling, and per-repository error handling stay consistent.

## Prerequisites

- No project `.env`, token file, or local clone configuration is required.
- `gh` must be installed and available on `PATH`.
- `gh` must be authenticated for `github.com`.
- `jq` must be installed and available on `PATH`.
- The authenticated account must have permission to list and sync the target forks.

## Default Workflow

1. Determine the scope and intent from the user's request: all personal forks, one owner, one repository, archived forks, a named branch, force sync, dry-run only, or actual execution.
2. Verify `gh` and `jq` are installed and `gh` is authenticated:

```bash
gh --version
jq --version
gh auth status
```

3. In sandboxed environments, `gh` may not see the user's keyring or real network context. If `gh auth status` fails in the sandbox, retry outside the sandbox before reporting an authentication failure. If the user explicitly asks to use the real/local `gh`, run `gh` outside the sandbox.
4. Resolve named repositories before syncing:
   - If the user provides exact `OWNER/REPO`, use that value with `--repo`.
   - If the user gives a natural-language name such as "cc switch", list forks and match normalized names: lowercase and ignore spaces, hyphens, and underscores.
   - If exactly one fork clearly matches, use that `OWNER/REPO`.
   - If multiple forks are plausible, show the candidates and ask which one to sync.
5. If the user did not specify an owner, let the script use the authenticated GitHub user.
6. For "which forks are behind?" questions, run the read-only status mode:

```bash
scripts/sync_github_forks.sh --status
```

7. Run a dry-run first unless the user explicitly requested immediate broad execution:

```bash
scripts/sync_github_forks.sh --dry-run
```

The dry-run compares forks first and prints planned actions instead of blindly listing every fork.

8. Execute after the dry-run result identifies the intended target and the user's intent allows execution:

```bash
scripts/sync_github_forks.sh --execute
```

9. Report a short summary: synced or planned, skipped, failed, diverged repositories requiring user approval, and the exact command to rerun if needed.

## Status and Verification

The script compares each fork default branch against its upstream parent's default branch before deciding what to do:

- `identical`: skip.
- `behind`: fast-forward safely.
- `ahead`: skip unless `--force` is explicitly provided.
- `diverged`: fail without `--force`; with explicit `--force`, hard reset style sync is allowed.
- `error`: report the repository, phase, and original error.

After any write, the script runs a focused compare and requires `behind=0`, `ahead=0`, and `status=identical` before counting the repository as succeeded.

Transient GitHub API errors such as EOF, connection reset, and timeouts are retried automatically before the repository is marked failed.

## Branch Name Mismatches

`gh repo sync` syncs a source branch to a matching destination branch. When the fork default branch and upstream default branch have different names, `gh repo sync` can return success without making the fork default branch identical to upstream.

The script detects default-branch name mismatches when `--branch` is not provided:

- If the fork is behind and not ahead, it fast-forwards the fork default branch with the Git refs API using `force=false`.
- If the fork is ahead or diverged, it uses the Git refs API with `force=true` only when the user explicitly provided `--force`.
- It verifies the result with compare after the refs update.

## Divergent Fork Recovery

When a non-force sync fails with `can't sync because there are diverging changes`, do not immediately force every fork. Summarize the divergent repositories and explain that `--force` discards the fork-side commits to match upstream.

If the user explicitly says to discard commits, discard local fork commits, force sync, overwrite, or accepts GitHub's "Discard commits" style action, run a scoped dry-run for only the failed divergent repositories:

```bash
scripts/sync_github_forks.sh --dry-run --force --repo OWNER/REPO --repo OWNER/OTHER
```

Then execute the same scoped command:

```bash
scripts/sync_github_forks.sh --execute --force --repo OWNER/REPO --repo OWNER/OTHER
```

Report the scoped force-sync result separately from the original broad sync.

If a force sync reports success but verification still reports a branch-name mismatch case, trust the script's final verification status. Do not claim the fork is updated unless the final compare says `identical`.

## If Prerequisites Are Missing

- If `gh --version` fails, stop and tell the user to install GitHub CLI before continuing.
- If `jq --version` fails, stop and tell the user to install `jq` before continuing.
- If `gh auth status` fails in a sandboxed environment, retry outside the sandbox before deciding authentication is invalid.
- If `gh auth status` fails outside the sandbox too, stop and ask the user to run:

```bash
gh auth login -h github.com
```

- Do not ask the user for a GitHub token unless they explicitly want a non-interactive setup. Prefer `gh auth login`.

## Script Usage

`scripts/sync_github_forks.sh` uses GitHub GraphQL through `gh api graphql` to find forked repositories and default branches, GitHub compare API to classify status, `gh repo sync` for normal matching-branch syncs, and Git refs API for default-branch mismatch cases.

Common commands:

```bash
# Check all non-archived forks and print behind/ahead status.
scripts/sync_github_forks.sh --status

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

# Force only explicitly approved diverged forks.
scripts/sync_github_forks.sh --execute --force --repo OWNER/REPO --repo OWNER/OTHER
```

## Decision Rules

- Use `--repo OWNER/REPO` when the user names one fork or asks to test the workflow on a single repository.
- For natural-language repository names, resolve candidates with `gh repo list OWNER --fork --json nameWithOwner,name,parent` before choosing `--repo`.
- If natural-language matching returns multiple plausible repositories, ask the user to choose instead of guessing.
- Use `--owner OWNER` when the user wants forks owned by a specific user or organization.
- Use `--branch BRANCH` only when the user asks for a specific branch; otherwise sync default branches. `--branch` disables default-branch mismatch handling because the user has requested a specific branch.
- Use `--include-archived` only when the user explicitly asks to include archived forks.
- Use `--force` only when the user explicitly asks for a force sync or hard reset style sync.
- Treat "discard commit(s)" for divergent fork sync failures as explicit permission to use `--force` only on the failed divergent repositories, after a scoped dry-run.
- If the user asks to update, sync, or refresh one named fork, treat that as permission to execute after a dry-run confirms the single intended repository.
- If the user asks to update, sync, or refresh all forks or another broad scope, run dry-run first and ask for approval unless the user explicitly requested immediate execution.
- If the user asks to run the skill without saying dry-run or execute and the scope is unclear, run `--dry-run`.

## Safety Rules

- Default to `--dry-run`; do not modify remote repositories unless the user requested execution.
- Do not pass `--force` unless the user explicitly asks for a hard reset style sync.
- Do not broaden a recovery force-sync beyond the repositories that failed from divergent changes unless the user explicitly asks for broad force sync.
- Default to non-archived repositories. Use `--include-archived` only when the user explicitly asks for archived forks too.
- Prefer syncing default branches. Use `--branch` only when the user asks for a specific branch.
- If sandboxed `gh auth status` fails, retry outside the sandbox before asking the user to re-authenticate with `gh auth login`.
- Do not execute when natural-language repository matching is ambiguous.
- If a repository fails to sync, continue to the next repository and summarize failures at the end with the phase and reason.

## Notes

- `gh repo sync OWNER/REPO` syncs a remote fork from its parent. Without `--force`, GitHub CLI uses a fast-forward update and fails rather than hard-resetting divergent work.
- GitHub CLI's sync success is not sufficient evidence for branch-name mismatch cases. Use the script's post-sync compare verification.
- This skill is for remote GitHub forks, not local working tree synchronization. For a single local clone, use normal `git fetch`, `git merge --ff-only`, or `gh repo sync` from that repository.
