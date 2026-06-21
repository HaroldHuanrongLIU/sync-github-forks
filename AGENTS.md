# Repository Guidelines

## Project Structure & Module Organization

This repository packages a Codex skill for syncing GitHub forks. `SKILL.md` is the root skill definition and user-facing workflow. `scripts/sync_github_forks.sh` contains the executable sync logic. `agents/openai.yaml` defines the OpenAI agent entry metadata. There is no separate source tree, test directory, or asset bundle at present.

## Build, Test, and Development Commands

- `bash -n scripts/sync_github_forks.sh`: check shell syntax without contacting GitHub.
- `gh auth status`: verify the GitHub CLI is installed and authenticated before running the sync workflow.
- `scripts/sync_github_forks.sh --dry-run`: list fork repositories and print the `gh repo sync` commands that would run. This is the default safe mode.
- `scripts/sync_github_forks.sh --repo OWNER/REPO --execute`: sync one fork; use this before broad execution when changing script behavior.
- `scripts/sync_github_forks.sh --execute`: sync all matching non-archived forks for the authenticated user.

## Coding Style & Naming Conventions

Shell code is Bash, not POSIX sh; arrays are used intentionally. Match the existing two-space indentation inside functions and control blocks. Keep helper names lowercase, such as `usage` and `die`, and keep configuration variables uppercase, such as `DRY_RUN`, `OWNER`, and `LIMIT`. Quote variable expansions unless arithmetic or array semantics require otherwise. YAML files should use two-space indentation and short, descriptive keys.

## Testing Guidelines

No automated test framework is configured yet. For script changes, run `bash -n` and then a dry run. When behavior changes could affect remote repositories, test with `--repo OWNER/REPO --dry-run` first, then execute against a single repository before running against all forks. Avoid `--force` in tests unless the change specifically concerns force-sync behavior.

## Commit & Pull Request Guidelines

This repository currently has no commit history to infer conventions from. Use concise imperative subjects with an optional scope, for example `docs: add contributor guide` or `fix: validate repo arguments`. Pull requests should describe the workflow impact, list the commands run, and include dry-run output when script behavior changes. Link related issues when available. Screenshots are usually unnecessary for this CLI-focused project.

## Security & Configuration Tips

The script operates on remote GitHub repositories through `gh`. Keep dry-run as the default, require explicit intent for `--execute`, and reserve `--force` for user-approved recovery cases. Do not commit tokens, local `gh` configuration, or command output containing private repository names unless intended.
