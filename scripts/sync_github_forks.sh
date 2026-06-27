#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
Usage: sync_github_forks.sh [options]

Batch check and sync GitHub fork repositories with gh CLI.

Options:
  --status               Compare forks with upstream and print behind/ahead status.
  --dry-run              Print the actions that would be taken. Default.
  --execute              Actually sync each repository that needs an update.
  --owner OWNER          GitHub user or organization to list forks from.
  --repo OWNER/REPO      Check or sync only one repository. May be repeated.
  --branch BRANCH        Pass --branch BRANCH to gh repo sync. Disables default-branch mismatch handling.
  --limit N              Maximum repos to list when enumerating forks. Default: 1000.
  --include-archived     Include archived fork repositories.
  --force                Hard reset style sync. Use only when explicitly intended.
  -h, --help             Show this help.

Examples:
  sync_github_forks.sh --status
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

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

is_transient_error() {
  case "$1" in
    *EOF*|*'connection reset'*|*'Connection reset'*|*timeout*|*Timeout*|*'TLS handshake timeout'*|*'temporary failure'*|*'Temporary failure'*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_with_retries() {
  local out_var="$1"
  shift

  local attempt=1
  local command_output
  local status

  while :; do
    command_output="$("$@" 2>&1)"
    status=$?
    if [ "$status" -eq 0 ]; then
      printf -v "$out_var" '%s' "$command_output"
      return 0
    fi

    if [ "$attempt" -lt "$API_RETRIES" ] && is_transient_error "$command_output"; then
      printf '  retrying after transient GitHub API error (attempt %d/%d)\n' "$attempt" "$API_RETRIES"
      attempt=$((attempt + 1))
      sleep "$RETRY_DELAY_SECONDS"
      continue
    fi

    printf -v "$out_var" '%s' "$command_output"
    return "$status"
  done
}

repo_parts() {
  local repo="$1"
  [ "$repo" != "${repo#*/}" ] || return 1
  printf '%s\t%s\n' "${repo%%/*}" "${repo#*/}"
}

metadata_for_repo() {
  local repo="$1"
  local owner
  local name
  local parts
  local output

  parts="$(repo_parts "$repo")" || {
    printf 'invalid repository name; expected OWNER/REPO'
    return 1
  }
  owner="${parts%%$'\t'*}"
  name="${parts#*$'\t'}"

  local query='query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      nameWithOwner
      isArchived
      defaultBranchRef { name }
      parent { nameWithOwner defaultBranchRef { name } }
    }
  }'

  if ! run_with_retries output gh api graphql -f owner="$owner" -f name="$name" -f query="$query" \
    --jq '.data.repository | [.nameWithOwner, (.defaultBranchRef.name // ""), .parent.nameWithOwner, (.parent.defaultBranchRef.name // ""), (.isArchived | tostring)] | @tsv'; then
    printf '%s' "$output"
    return 1
  fi

  printf '%s\n' "$output"
}

list_fork_metadata() {
  local owner="$1"
  local output
  local archived_filter

  if [ "$INCLUDE_ARCHIVED" -eq 1 ]; then
    archived_filter='true'
  else
    archived_filter='(.isArchived | not)'
  fi

  local query='query($owner: String!, $endCursor: String) {
    repositoryOwner(login: $owner) {
      repositories(first: 100, after: $endCursor, isFork: true) {
        pageInfo { hasNextPage endCursor }
        nodes {
          nameWithOwner
          isArchived
          defaultBranchRef { name }
          parent { nameWithOwner defaultBranchRef { name } }
        }
      }
    }
  }'

  if ! run_with_retries output gh api graphql --paginate -f owner="$owner" -f query="$query" \
    --jq ".data.repositoryOwner.repositories.nodes[] | select(.parent != null and $archived_filter) | [.nameWithOwner, (.defaultBranchRef.name // \"\"), .parent.nameWithOwner, (.parent.defaultBranchRef.name // \"\"), (.isArchived | tostring)] | @tsv"; then
    printf '%s' "$output"
    return 1
  fi

  printf '%s\n' "$output" | sed -n "1,${LIMIT}p"
}

load_metadata() {
  METADATA_ROWS=()

  local row
  local output
  local repo

  if [ "${#REPOS[@]}" -gt 0 ]; then
    for repo in "${REPOS[@]}"; do
      if ! output="$(metadata_for_repo "$repo")"; then
        FAILED_REPOS+=("$repo	metadata	$output")
        continue
      fi
      while IFS= read -r row; do
        [ -n "$row" ] && METADATA_ROWS+=("$row")
      done <<EOF
$output
EOF
    done
    return 0
  fi

  if [ -z "$OWNER" ]; then
    if ! run_with_retries OWNER gh api user --jq '.login'; then
      die "failed to determine authenticated GitHub user: $OWNER"
    fi
  fi

  if ! output="$(list_fork_metadata "$OWNER")"; then
    die "failed to list fork repositories: $output"
  fi

  while IFS= read -r row; do
    [ -n "$row" ] && METADATA_ROWS+=("$row")
  done <<EOF
$output
EOF
}

compare_record() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local output
  local fork_owner
  local base_enc
  local head_enc

  if [ -z "$fork_branch" ]; then
    printf 'error\t0\t0\tmissing fork default branch'
    return 1
  fi

  if [ -z "$parent_repo" ] || [ -z "$parent_branch" ]; then
    printf 'error\t0\t0\tmissing upstream repository or default branch'
    return 1
  fi

  fork_owner="${repo%%/*}"
  base_enc="$(urlencode "$parent_branch")"
  head_enc="$(urlencode "$fork_branch")"

  if ! run_with_retries output gh api "repos/$parent_repo/compare/$base_enc...$fork_owner:$head_enc" \
    --jq '[.status, .behind_by, .ahead_by] | @tsv'; then
    printf 'error\t0\t0\t%s' "$output"
    return 1
  fi

  printf '%s' "$output"
}

upstream_sha() {
  local parent_repo="$1"
  local parent_branch="$2"
  local branch_enc
  local output

  branch_enc="$(urlencode "$parent_branch")"
  if ! run_with_retries output gh api "repos/$parent_repo/branches/$branch_enc" --jq '.commit.sha'; then
    printf '%s' "$output"
    return 1
  fi

  printf '%s' "$output"
}

update_fork_ref() {
  local repo="$1"
  local fork_branch="$2"
  local sha="$3"
  local force_value="$4"
  local branch_enc
  local output

  branch_enc="$(urlencode "$fork_branch")"
  if ! run_with_retries output gh api -X PATCH "repos/$repo/git/refs/heads/$branch_enc" \
    -f sha="$sha" -F force="$force_value" --jq '.ref'; then
    printf '%s' "$output"
    return 1
  fi

  printf '%s' "$output"
}

verify_identical() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local compare
  local status
  local behind
  local ahead

  if ! compare="$(compare_record "$repo" "$fork_branch" "$parent_repo" "$parent_branch")"; then
    printf '%s' "$compare"
    return 1
  fi

  IFS=$'\t' read -r status behind ahead <<< "$compare"
  if [ "$status" = "identical" ] && [ "$behind" = "0" ] && [ "$ahead" = "0" ]; then
    printf 'verified identical'
    return 0
  fi

  printf 'verification failed: status=%s behind=%s ahead=%s' "$status" "$behind" "$ahead"
  return 1
}

sync_with_gh() {
  local repo="$1"
  local use_force="$2"
  local output
  local args=(repo sync "$repo")

  [ -n "$BRANCH" ] && args+=(--branch "$BRANCH")
  [ "$use_force" -eq 1 ] && args+=(--force)

  if ! run_with_retries output gh "${args[@]}"; then
    printf '%s' "$output"
    return 1
  fi

  [ -n "$output" ] && printf '%s\n' "$output"
  return 0
}

sync_by_ref() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local use_force="$5"
  local sha
  local force_value=false
  local output

  [ "$use_force" -eq 1 ] && force_value=true

  if ! sha="$(upstream_sha "$parent_repo" "$parent_branch")"; then
    printf '%s' "$sha"
    return 1
  fi

  if ! output="$(update_fork_ref "$repo" "$fork_branch" "$sha" "$force_value")"; then
    printf '%s' "$output"
    return 1
  fi

  printf 'updated %s from %s@%s with force=%s\n' "$fork_branch" "$parent_repo" "$parent_branch" "$force_value"
  return 0
}

print_status_line() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local status="$5"
  local behind="$6"
  local ahead="$7"

  printf '%s\tbehind=%s\tahead=%s\tstatus=%s\tfork_branch=%s\tupstream=%s\tupstream_branch=%s\n' \
    "$repo" "$behind" "$ahead" "$status" "$fork_branch" "$parent_repo" "$parent_branch"
}

dry_run_action() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local status="$5"
  local behind="$6"
  local ahead="$7"
  local branch_mismatch=0

  [ "$fork_branch" != "$parent_branch" ] && [ -z "$BRANCH" ] && branch_mismatch=1

  case "$status" in
    identical)
      printf '  skip %s status=identical\n' "$repo"
      return 1
      ;;
    ahead)
      if [ "$FORCE" -eq 1 ]; then
        if [ "$branch_mismatch" -eq 1 ]; then
          printf '  force-reset %s %s <- %s@%s\n' "$repo" "$fork_branch" "$parent_repo" "$parent_branch"
        else
          printf '  gh repo sync %s --force\n' "$repo"
        fi
        return 0
      fi
      printf '  skip %s status=ahead ahead=%s\n' "$repo" "$ahead"
      return 1
      ;;
    behind)
      if [ "$branch_mismatch" -eq 1 ]; then
        printf '  fast-forward %s %s <- %s@%s\n' "$repo" "$fork_branch" "$parent_repo" "$parent_branch"
      else
        printf '  gh repo sync %s\n' "$repo"
      fi
      return 0
      ;;
    diverged)
      if [ "$FORCE" -eq 1 ]; then
        if [ "$branch_mismatch" -eq 1 ]; then
          printf '  force-reset %s %s <- %s@%s\n' "$repo" "$fork_branch" "$parent_repo" "$parent_branch"
        else
          printf '  gh repo sync %s --force\n' "$repo"
        fi
        return 0
      fi
      printf '  needs-force %s behind=%s ahead=%s\n' "$repo" "$behind" "$ahead"
      return 1
      ;;
    *)
      printf '  error %s status=%s\n' "$repo" "$status"
      return 1
      ;;
  esac
}

execute_action() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local status="$5"
  local behind="$6"
  local ahead="$7"
  local branch_mismatch=0
  local output
  local verify
  local use_force=0

  [ "$fork_branch" != "$parent_branch" ] && [ -z "$BRANCH" ] && branch_mismatch=1

  printf '\n==> %s\n' "$repo"
  printf 'status=%s behind=%s ahead=%s fork_branch=%s upstream=%s upstream_branch=%s\n' \
    "$status" "$behind" "$ahead" "$fork_branch" "$parent_repo" "$parent_branch"

  case "$status" in
    identical)
      printf 'skipped: already identical\n'
      return 2
      ;;
    ahead)
      if [ "$FORCE" -eq 0 ]; then
        printf 'skipped: fork is ahead; use --force only when discarding fork-side commits is intended\n'
        return 2
      fi
      use_force=1
      ;;
    behind)
      use_force=0
      ;;
    diverged)
      if [ "$FORCE" -eq 0 ]; then
        printf "can't sync because there are diverging changes; use --force to overwrite the destination branch\n"
        return 3
      fi
      use_force=1
      ;;
    *)
      printf 'failed: cannot sync repository with status=%s\n' "$status"
      return 1
      ;;
  esac

  if [ "$branch_mismatch" -eq 1 ]; then
    if ! output="$(sync_by_ref "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$use_force")"; then
      printf 'failed: %s\n' "$output"
      return 1
    fi
    printf '%s' "$output"
  else
    if ! output="$(sync_with_gh "$repo" "$use_force")"; then
      printf 'failed: %s\n' "$output"
      return 1
    fi
    [ -n "$output" ] && printf '%s' "$output"
  fi

  if ! verify="$(verify_identical "$repo" "$fork_branch" "$parent_repo" "$parent_branch")"; then
    printf 'failed: %s\n' "$verify"
    return 1
  fi

  printf '%s\n' "$verify"
  return 0
}

DRY_RUN=1
STATUS_ONLY=0
OWNER=""
BRANCH=""
LIMIT=1000
INCLUDE_ARCHIVED=0
FORCE=0
API_RETRIES=3
RETRY_DELAY_SECONDS=1
REPOS=()
METADATA_ROWS=()
FAILED_REPOS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --status|--check-behind)
      STATUS_ONLY=1
      DRY_RUN=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --execute)
      DRY_RUN=0
      STATUS_ONLY=0
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
command -v jq >/dev/null 2>&1 || die "jq is not installed or not on PATH"

if ! gh auth status >/dev/null 2>&1; then
  gh auth status >&2
  die "gh authentication is not valid; run: gh auth login -h github.com"
fi

load_metadata

if [ "${#METADATA_ROWS[@]}" -eq 0 ]; then
  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
    printf 'No repositories could be loaded.\n'
    printf 'Failed repositories:\n' >&2
    printf '  %s\n' "${FAILED_REPOS[@]}" >&2
    exit 1
  fi
  printf 'No fork repositories found.\n'
  exit 0
fi

if [ "$STATUS_ONLY" -eq 1 ]; then
  printf 'Status. %d repositories checked:\n' "${#METADATA_ROWS[@]}"
elif [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run. %d repositories checked:\n' "${#METADATA_ROWS[@]}"
else
  printf 'Syncing %d repositories with status checks.\n' "${#METADATA_ROWS[@]}"
fi

success=0
skipped=0
failed=0
planned=0
behind_count=0
ahead_count=0
diverged_count=0
identical_count=0

for row in "${METADATA_ROWS[@]}"; do
  IFS=$'\t' read -r repo fork_branch parent_repo parent_branch _archived <<< "$row"
  if [ -n "$BRANCH" ]; then
    fork_branch="$BRANCH"
    parent_branch="$BRANCH"
  fi

  compare="$(compare_record "$repo" "$fork_branch" "$parent_repo" "$parent_branch")"
  compare_status=$?
  IFS=$'\t' read -r status behind ahead message <<< "$compare"

  if [ "$compare_status" -ne 0 ]; then
    failed=$((failed + 1))
    FAILED_REPOS+=("$repo	compare	$message")
    if [ "$STATUS_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
      print_status_line "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "error" 0 0
    else
      printf '\n==> %s\nfailed: compare error: %s\n' "$repo" "$message"
    fi
    continue
  fi

  case "$status" in
    behind) behind_count=$((behind_count + 1)) ;;
    ahead) ahead_count=$((ahead_count + 1)) ;;
    diverged) diverged_count=$((diverged_count + 1)) ;;
    identical) identical_count=$((identical_count + 1)) ;;
  esac

  if [ "$STATUS_ONLY" -eq 1 ]; then
    print_status_line "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if dry_run_action "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead"; then
      planned=$((planned + 1))
    else
      skipped=$((skipped + 1))
    fi
    continue
  fi

  execute_action "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead"
  action_status=$?
  case "$action_status" in
    0)
      success=$((success + 1))
      ;;
    2)
      skipped=$((skipped + 1))
      ;;
    3)
      failed=$((failed + 1))
      FAILED_REPOS+=("$repo	diverged	behind=$behind ahead=$ahead")
      ;;
    *)
      failed=$((failed + 1))
      FAILED_REPOS+=("$repo	sync	status=$status behind=$behind ahead=$ahead")
      ;;
  esac
done

if [ "$STATUS_ONLY" -eq 1 ]; then
  printf '\nSummary: %d identical, %d behind, %d ahead, %d diverged, %d failed.\n' \
    "$identical_count" "$behind_count" "$ahead_count" "$diverged_count" "$failed"
elif [ "$DRY_RUN" -eq 1 ]; then
  printf '\nSummary: %d planned, %d skipped, %d failed.\n' "$planned" "$skipped" "$failed"
else
  printf '\nSummary: %d succeeded, %d skipped, %d failed.\n' "$success" "$skipped" "$failed"
fi

if [ "$failed" -gt 0 ]; then
  printf 'Failed repositories:\n' >&2
  for repo in "${FAILED_REPOS[@]}"; do
    printf '  %s\n' "$repo" >&2
  done
  exit 1
fi
