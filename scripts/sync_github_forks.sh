#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
Usage: sync_github_forks.sh [options]

Batch sync GitHub fork repositories with gh CLI.

Options:
  --dry-run              Print the repositories that would be synced. Default.
  --execute              Actually run gh repo sync for each repository.
  --owner OWNER          GitHub user or organization to list forks from.
  --repo OWNER/REPO      Sync only one repository. May be repeated.
  --branch BRANCH        Pass --branch BRANCH to gh repo sync.
  --limit N              Maximum repos to list when enumerating forks. Default: 1000.
  --include-archived     Include archived fork repositories.
  --force                Pass --force to gh repo sync. Use only when explicitly intended.
  -h, --help             Show this help.

Examples:
  sync_github_forks.sh --dry-run
  sync_github_forks.sh --execute
  sync_github_forks.sh --owner my-user --execute
  sync_github_forks.sh --repo my-user/my-fork --execute
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

DRY_RUN=1
OWNER=""
BRANCH=""
LIMIT=1000
INCLUDE_ARCHIVED=0
FORCE=0
REPOS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --execute)
      DRY_RUN=0
      shift
      ;;
    --owner)
      [ "$#" -ge 2 ] || die "--owner requires a value"
      OWNER="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires OWNER/REPO"
      REPOS+=("$2")
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || die "--branch requires a value"
      BRANCH="$2"
      shift 2
      ;;
    --limit)
      [ "$#" -ge 2 ] || die "--limit requires a positive integer"
      LIMIT="$2"
      shift 2
      ;;
    --include-archived)
      INCLUDE_ARCHIVED=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*)
    die "--limit must be a positive integer"
    ;;
esac

[ "$LIMIT" -gt 0 ] || die "--limit must be greater than zero"

command -v gh >/dev/null 2>&1 || die "gh CLI is not installed or not on PATH"

if ! gh auth status >/dev/null 2>&1; then
  gh auth status >&2
  die "gh authentication is not valid; run: gh auth login -h github.com"
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
  if [ -z "$OWNER" ]; then
    OWNER="$(gh api user --jq '.login')" || die "failed to determine authenticated GitHub user"
  fi

  list_args=(repo list "$OWNER" --fork --limit "$LIMIT" --json nameWithOwner,parent)
  if [ "$INCLUDE_ARCHIVED" -eq 0 ]; then
    list_args+=(--no-archived)
  fi

  repos_text="$(gh "${list_args[@]}" --jq '.[] | select(.parent != null) | .nameWithOwner')" || die "failed to list fork repositories"
  while IFS= read -r repo; do
    [ -n "$repo" ] && REPOS+=("$repo")
  done <<EOF
$repos_text
EOF
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
  printf 'No fork repositories found.\n'
  exit 0
fi

sync_args=()
[ -n "$BRANCH" ] && sync_args+=(--branch "$BRANCH")
[ "$FORCE" -eq 1 ] && sync_args+=(--force)

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run. %d repositories would be synced:\n' "${#REPOS[@]}"
else
  printf 'Syncing %d repositories with gh repo sync.\n' "${#REPOS[@]}"
fi

success=0
failed=0
failed_repos=()

for repo in "${REPOS[@]}"; do
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  gh repo sync %s' "$repo"
    if [ "${#sync_args[@]}" -gt 0 ]; then
      printf ' %q' "${sync_args[@]}"
    fi
    printf '\n'
    success=$((success + 1))
    continue
  fi

  printf '\n==> %s\n' "$repo"
  if gh repo sync "$repo" "${sync_args[@]}"; then
    success=$((success + 1))
  else
    failed=$((failed + 1))
    failed_repos+=("$repo")
    printf 'failed: %s\n' "$repo" >&2
  fi
done

printf '\nSummary: %d succeeded, %d failed.\n' "$success" "$failed"

if [ "$failed" -gt 0 ]; then
  printf 'Failed repositories:\n' >&2
  for repo in "${failed_repos[@]}"; do
    printf '  %s\n' "$repo" >&2
  done
  exit 1
fi
