# Sync GitHub Forks

Codex skill package for checking and batch-synchronizing GitHub fork repositories from their upstream parents with GitHub CLI.

The skill instructions live in `SKILL.md`. The reusable implementation lives in `scripts/sync_github_forks.sh`.

## Requirements

- GitHub CLI (`gh`) installed and available on `PATH`
- `jq` installed and available on `PATH`
- Authenticated GitHub CLI session for `github.com`
- Permission to list and sync the target fork repositories

No project `.env`, token file, or local clone configuration is required.

Check the environment:

```bash
gh --version
jq --version
gh auth status
```

If authentication is missing:

```bash
gh auth login -h github.com
```

## Usage

Check fork status without changing remote repositories:

```bash
scripts/sync_github_forks.sh --status
```

Preview the forks that would be synced:

```bash
scripts/sync_github_forks.sh --dry-run
```

Sync all non-archived forks for the authenticated user:

```bash
scripts/sync_github_forks.sh --execute
```

Sync one repository:

```bash
scripts/sync_github_forks.sh --repo OWNER/REPO --execute
```

Sync forks owned by a specific user or organization:

```bash
scripts/sync_github_forks.sh --owner OWNER --execute
```

Force only explicitly approved diverged forks:

```bash
scripts/sync_github_forks.sh --execute --force --repo OWNER/REPO --repo OWNER/OTHER
```

## Safety

Dry-run mode is the default. The script compares each fork with its upstream first, skips identical repositories, and verifies writes with a focused compare. Use `--execute` only after reviewing the dry-run output. Use `--force` only when intentionally discarding fork-side commits.

By default, archived repositories are excluded. Add `--include-archived` only when archived forks should be considered.

When a fork default branch has a different name from the upstream default branch, the script uses Git refs API updates and verifies the result. Non-force updates use `force=false`; destructive resets require `--force`.

## Development

Validate shell syntax before changing behavior:

```bash
bash -n scripts/sync_github_forks.sh
```

Run the mocked behavior tests:

```bash
bash tests/sync_github_forks_test.sh
```

After editing skill metadata or workflow instructions, validate the skill package if the local Codex skill validator is available.
