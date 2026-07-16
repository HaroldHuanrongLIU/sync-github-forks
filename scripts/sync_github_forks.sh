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
  --format FORMAT        Output format: human, tsv, or json. Default: human.
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

record_failure() {
  local repo="$1"
  local phase="$2"
  local message="$3"
  local record

  record="$(jq -cn \
    --arg repo "$repo" \
    --arg phase "$phase" \
    --arg message "$message" \
    '{repo: $repo, phase: $phase, message: $message}')"
  FAILED_REPOS+=("$record")
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

is_transient_error() {
  case "$1" in
    *EOF*|*'connection reset'*|*'Connection reset'*|*timeout*|*Timeout*|*'TLS handshake timeout'*|*'temporary failure'*|*'Temporary failure'*|*'invalid character'*|*'unexpected token'*|*'looking for beginning of value'*|*'unexpected end of JSON input'*|*'parse error:'*|*'<html'*|*'<HTML'*)
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
      printf '  retrying after transient GitHub API error (attempt %d/%d)\n' "$attempt" "$API_RETRIES" >&2
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

fetch_fork_page() {
  local owner="$1"
  local end_cursor="$2"
  local output
  local parsed
  local args

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

  args=(gh api graphql -f owner="$owner" -f query="$query")
  [ -n "$end_cursor" ] && args+=(-f endCursor="$end_cursor")

  if ! output="$("${args[@]}" 2>&1)"; then
    printf '%s' "$output"
    return 1
  fi

  if ! parsed="$(jq -r --argjson include_archived "$INCLUDE_ARCHIVED" '
    .data.repositoryOwner.repositories as $repos
    | (["page", ($repos.pageInfo.hasNextPage | tostring), ($repos.pageInfo.endCursor // "")] | @tsv),
      ($repos.nodes[]
        | select(.parent != null)
        | select($include_archived == 1 or (.isArchived | not))
        | [
            .nameWithOwner,
            (.defaultBranchRef.name // ""),
            .parent.nameWithOwner,
            (.parent.defaultBranchRef.name // ""),
            (.isArchived | tostring)
          ]
        | @tsv)
  ' <<< "$output" 2>&1)"; then
    printf '%s' "$parsed"
    return 1
  fi

  printf '%s\n' "$parsed"
}

list_fork_metadata() {
  local owner="$1"
  local page_output
  local row
  local page_type
  local has_next
  local end_cursor
  local cursor=""
  local count=0
  local first_row
  local rows=()

  while :; do
    if ! run_with_retries page_output fetch_fork_page "$owner" "$cursor"; then
      printf '%s' "$page_output"
      return 1
    fi

    first_row=1
    while IFS= read -r row; do
      if [ "$first_row" -eq 1 ]; then
        IFS=$'\t' read -r page_type has_next end_cursor <<< "$row"
        [ "$page_type" = "page" ] || {
          printf 'invalid fork page metadata'
          return 1
        }
        first_row=0
        continue
      fi

      [ -n "$row" ] || continue
      rows+=("$row")
      count=$((count + 1))
      [ "$count" -ge "$LIMIT" ] && break
    done <<EOF
$page_output
EOF

    if [ "$count" -ge "$LIMIT" ] || [ "$has_next" = "false" ]; then
      break
    fi

    [ "$has_next" = "true" ] && [ -n "$end_cursor" ] || {
      printf 'invalid fork page cursor'
      return 1
    }
    cursor="$end_cursor"
  done

  if [ "${#rows[@]}" -gt 0 ]; then
    printf '%s\n' "${rows[@]}"
  fi
}

load_metadata() {
  METADATA_ROWS=()

  local row
  local output
  local repo

  if [ "${#REPOS[@]}" -gt 0 ]; then
    for repo in "${REPOS[@]}"; do
      if ! output="$(metadata_for_repo "$repo")"; then
        record_failure "$repo" "metadata" "$output"
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
    printf '%s' "$output"
    return 1
  fi

  printf '%s' "$output"
}

parse_compare_record() {
  local record="$1"
  local pattern=$'^(identical|behind|ahead|diverged)\t([0-9]+)\t([0-9]+)$'

  if [[ "$record" =~ $pattern ]]; then
    PARSED_STATUS="${BASH_REMATCH[1]}"
    PARSED_BEHIND="${BASH_REMATCH[2]}"
    PARSED_AHEAD="${BASH_REMATCH[3]}"
    return 0
  fi

  COMPARE_ERROR="invalid compare response: $record"
  return 1
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

  if ! parse_compare_record "$compare"; then
    printf '%s' "$COMPARE_ERROR"
    return 1
  fi

  status="$PARSED_STATUS"
  behind="$PARSED_BEHIND"
  ahead="$PARSED_AHEAD"
  if [ "$status" = "identical" ] && [ "$behind" = "0" ] && [ "$ahead" = "0" ]; then
    printf 'verified identical'
    return 0
  fi

  printf 'verification failed: status=%s behind=%s ahead=%s' "$status" "$behind" "$ahead"
  return 1
}

verify_with_retry() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local verify
  local attempt=1

  while [ "$attempt" -le 3 ]; do
    if verify="$(verify_identical "$repo" "$fork_branch" "$parent_repo" "$parent_branch")"; then
      printf '%s\n' "$verify"
      return 0
    fi

    if [ "$attempt" -lt 3 ] && [[ "$verify" == *"status=behind"* ]]; then
      printf '  verification shows repository still behind, retrying in %d seconds (attempt %d/3)\n' "$RETRY_DELAY_SECONDS" "$attempt" >&2
      sleep "$RETRY_DELAY_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi

    printf '%s\n' "$verify"
    return 1
  done
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

human_printf() {
  if [ "$FORMAT" = "human" ]; then
    printf "$@"
  fi
}

add_result() {
  local repo="$1"
  local fork_branch="$2"
  local parent_repo="$3"
  local parent_branch="$4"
  local status="$5"
  local behind="$6"
  local ahead="$7"
  local action="$8"
  local result="$9"
  local message="${10}"
  local record

  record="$(jq -cn \
    --arg type "repository" \
    --arg repo "$repo" \
    --arg fork_branch "$fork_branch" \
    --arg upstream "$parent_repo" \
    --arg upstream_branch "$parent_branch" \
    --arg status "$status" \
    --argjson behind "$behind" \
    --argjson ahead "$ahead" \
    --arg action "$action" \
    --arg result "$result" \
    --arg message "$message" \
    '{
      type: $type,
      repo: $repo,
      fork_branch: $fork_branch,
      upstream: $upstream,
      upstream_branch: $upstream_branch,
      status: $status,
      behind: $behind,
      ahead: $ahead,
      action: $action,
      result: $result,
      message: $message
    }')"
  RESULT_ROWS+=("$record")
}

render_json() {
  local record
  local first=1
  local checked="${#RESULT_ROWS[@]}"
  local summary

  printf '{"repositories":['
  for record in "${RESULT_ROWS[@]}"; do
    if [ "$first" -eq 0 ]; then
      printf ','
    fi
    printf '%s' "$record"
    first=0
  done

  summary="$(jq -cn \
    --arg mode "$MODE" \
    --argjson checked "$checked" \
    --argjson identical "$identical_count" \
    --argjson behind "$behind_count" \
    --argjson ahead "$ahead_count" \
    --argjson diverged "$diverged_count" \
    --argjson failed "$failed" \
    --argjson planned "$planned" \
    --argjson succeeded "$success" \
    --argjson blocked "$blocked" \
    '{
      mode: $mode,
      checked: $checked,
      identical: $identical,
      behind: $behind,
      ahead: $ahead,
      diverged: $diverged,
      failed: $failed,
      planned: $planned,
      succeeded: $succeeded,
      blocked: $blocked
    }')"
  printf '],"summary":%s}\n' "$summary"
}

render_tsv() {
  local record
  local checked="${#RESULT_ROWS[@]}"

  printf 'type\trepo\tfork_branch\tupstream\tupstream_branch\tstatus\tbehind\tahead\taction\tresult\tmessage\tmode\tchecked\tidentical_count\tbehind_count\tahead_count\tdiverged_count\tfailed_count\tplanned_count\tsucceeded_count\tblocked_count\n'
  for record in "${RESULT_ROWS[@]}"; do
    jq -r '[
      .type,
      .repo,
      .fork_branch,
      .upstream,
      .upstream_branch,
      .status,
      .behind,
      .ahead,
      .action,
      .result,
      (.message | gsub("[\t\r\n]"; " ")),
      "", "", "", "", "", "", "", "", "", ""
    ] | @tsv' <<< "$record"
  done

  jq -rn \
    --arg mode "$MODE" \
    --argjson checked "$checked" \
    --argjson identical "$identical_count" \
    --argjson behind "$behind_count" \
    --argjson ahead "$ahead_count" \
    --argjson diverged "$diverged_count" \
    --argjson failed "$failed" \
    --argjson planned "$planned" \
    --argjson succeeded "$success" \
    --argjson blocked "$blocked" \
    '[
      "summary",
      "", "", "", "", "", "", "", "", "", "",
      $mode,
      $checked,
      $identical,
      $behind,
      $ahead,
      $diverged,
      $failed,
      $planned,
      $succeeded,
      $blocked
    ] | @tsv'
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

  LAST_ACTION="skip"
  LAST_RESULT="error"
  LAST_MESSAGE="unsupported status"

  [ "$fork_branch" != "$parent_branch" ] && [ -z "$BRANCH" ] && branch_mismatch=1

  case "$status" in
    identical)
      LAST_RESULT="identical"
      LAST_MESSAGE="already identical"
      human_printf '  skip %s status=identical\n' "$repo"
      return 1
      ;;
    ahead)
      if [ "$FORCE" -eq 1 ]; then
        if [ "$branch_mismatch" -eq 1 ]; then
          LAST_ACTION="force-reset"
          human_printf '  force-reset %s %s <- %s@%s\n' "$repo" "$fork_branch" "$parent_repo" "$parent_branch"
        else
          LAST_ACTION="force-sync"
          human_printf '  gh repo sync %s --force\n' "$repo"
        fi
        LAST_RESULT="planned"
        LAST_MESSAGE="force sync planned"
        return 0
      fi
      LAST_RESULT="ahead"
      LAST_MESSAGE="fork is ahead"
      human_printf '  skip %s status=ahead ahead=%s\n' "$repo" "$ahead"
      return 1
      ;;
    behind)
      if [ "$branch_mismatch" -eq 1 ]; then
        LAST_ACTION="fast-forward"
        human_printf '  fast-forward %s %s <- %s@%s\n' "$repo" "$fork_branch" "$parent_repo" "$parent_branch"
      else
        LAST_ACTION="sync"
        human_printf '  gh repo sync %s\n' "$repo"
      fi
      LAST_RESULT="planned"
      LAST_MESSAGE="safe fast-forward"
      return 0
      ;;
    diverged)
      if [ "$FORCE" -eq 1 ]; then
        if [ "$branch_mismatch" -eq 1 ]; then
          LAST_ACTION="force-reset"
          human_printf '  force-reset %s %s <- %s@%s\n' "$repo" "$fork_branch" "$parent_repo" "$parent_branch"
        else
          LAST_ACTION="force-sync"
          human_printf '  gh repo sync %s --force\n' "$repo"
        fi
        LAST_RESULT="planned"
        LAST_MESSAGE="force sync planned"
        return 0
      fi
      LAST_RESULT="blocked"
      LAST_MESSAGE="diverged; force required"
      human_printf '  needs-force %s behind=%s ahead=%s\n' "$repo" "$behind" "$ahead"
      return 1
      ;;
    *)
      LAST_RESULT="error"
      LAST_MESSAGE="unsupported status: $status"
      human_printf '  error %s status=%s\n' "$repo" "$status"
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

  LAST_ACTION="sync"
  LAST_RESULT="error"
  LAST_MESSAGE="sync failed"

  [ "$fork_branch" != "$parent_branch" ] && [ -z "$BRANCH" ] && branch_mismatch=1

  human_printf '\n==> %s\n' "$repo"
  human_printf 'status=%s behind=%s ahead=%s fork_branch=%s upstream=%s upstream_branch=%s\n' \
    "$status" "$behind" "$ahead" "$fork_branch" "$parent_repo" "$parent_branch"

  case "$status" in
    identical)
      LAST_ACTION="skip"
      LAST_RESULT="identical"
      LAST_MESSAGE="already identical"
      human_printf 'skipped: already identical\n'
      return 2
      ;;
    ahead)
      if [ "$FORCE" -eq 0 ]; then
        LAST_ACTION="skip"
        LAST_RESULT="ahead"
        LAST_MESSAGE="fork is ahead"
        human_printf 'skipped: fork is ahead; use --force only when discarding fork-side commits is intended\n'
        return 2
      fi
      use_force=1
      ;;
    behind)
      use_force=0
      ;;
    diverged)
      if [ "$FORCE" -eq 0 ]; then
        LAST_ACTION="skip"
        LAST_RESULT="blocked"
        LAST_MESSAGE="diverged; force required"
        human_printf "can't sync because there are diverging changes; use --force to overwrite the destination branch\n"
        return 3
      fi
      use_force=1
      ;;
    *)
      LAST_RESULT="error"
      LAST_MESSAGE="cannot sync repository with status=$status"
      human_printf 'failed: cannot sync repository with status=%s\n' "$status"
      return 1
      ;;
  esac

  if [ "$branch_mismatch" -eq 1 ]; then
    if [ "$use_force" -eq 1 ]; then
      LAST_ACTION="force-reset"
    else
      LAST_ACTION="fast-forward"
    fi
    if ! output="$(sync_by_ref "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$use_force")"; then
      LAST_RESULT="error"
      LAST_MESSAGE="$output"
      human_printf 'failed: %s\n' "$output"
      return 1
    fi
    human_printf '%s' "$output"
  else
    if [ "$use_force" -eq 1 ]; then
      LAST_ACTION="force-sync"
    else
      LAST_ACTION="sync"
    fi
    if ! output="$(sync_with_gh "$repo" "$use_force")"; then
      LAST_RESULT="error"
      LAST_MESSAGE="$output"
      human_printf 'failed: %s\n' "$output"
      return 1
    fi
    [ -n "$output" ] && human_printf '%s' "$output"
  fi

  if ! verify="$(verify_with_retry "$repo" "$fork_branch" "$parent_repo" "$parent_branch")"; then
    LAST_RESULT="error"
    LAST_MESSAGE="$verify"
    human_printf 'failed: %s\n' "$verify"
    return 1
  fi

  LAST_RESULT="succeeded"
  LAST_MESSAGE="$verify"
  human_printf '%s\n' "$verify"
  return 0
}

DRY_RUN=1
STATUS_ONLY=0
OWNER=""
BRANCH=""
FORMAT="human"
LIMIT=1000
INCLUDE_ARCHIVED=0
FORCE=0
API_RETRIES=3
RETRY_DELAY_SECONDS=1
REPOS=()
METADATA_ROWS=()
FAILED_REPOS=()
RESULT_ROWS=()

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
    --format)
      [ "$#" -ge 2 ] || die "--format requires a value"
      FORMAT="$2"
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

case "$FORMAT" in
  human|tsv|json) ;;
  *) die "--format must be one of: human, tsv, json" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh CLI is not installed or not on PATH"
command -v jq >/dev/null 2>&1 || die "jq is not installed or not on PATH"

if ! gh auth status >/dev/null 2>&1; then
  gh auth status >&2
  die "gh authentication is not valid; run: gh auth login -h github.com"
fi

if [ "$STATUS_ONLY" -eq 1 ]; then
  MODE="status"
elif [ "$DRY_RUN" -eq 1 ]; then
  MODE="dry-run"
else
  MODE="execute"
fi

success=0
skipped=0
failed=0
planned=0
behind_count=0
ahead_count=0
diverged_count=0
identical_count=0
blocked=0

load_metadata

failed="${#FAILED_REPOS[@]}"
if [ "$FORMAT" != "human" ] && [ "$failed" -gt 0 ]; then
  for failed_record in "${FAILED_REPOS[@]}"; do
    failed_repo="$(jq -r '.repo' <<< "$failed_record")"
    failed_phase="$(jq -r '.phase' <<< "$failed_record")"
    failed_message="$(jq -r '.message' <<< "$failed_record")"
    add_result "$failed_repo" "" "" "" "error" 0 0 "check" "error" "$failed_phase: $failed_message"
  done
fi

if [ "${#METADATA_ROWS[@]}" -eq 0 ]; then
  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
    if [ "$FORMAT" = "json" ]; then
      render_json
    elif [ "$FORMAT" = "tsv" ]; then
      render_tsv
    else
      printf 'No repositories could be loaded.\n'
      printf 'Failed repositories:\n' >&2
      for failed_record in "${FAILED_REPOS[@]}"; do
        jq -r '"  \(.repo)\t\(.phase)\t\(.message)"' <<< "$failed_record" >&2
      done
    fi
    exit 1
  fi
  if [ "$FORMAT" = "json" ]; then
    render_json
  elif [ "$FORMAT" = "tsv" ]; then
    render_tsv
  else
    printf 'No fork repositories found.\n'
  fi
  exit 0
fi

if [ "$FORMAT" = "human" ] && [ "$STATUS_ONLY" -eq 1 ]; then
  printf 'Status. %d repositories checked:\n' "${#METADATA_ROWS[@]}"
elif [ "$FORMAT" = "human" ] && [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run. %d repositories checked:\n' "${#METADATA_ROWS[@]}"
elif [ "$FORMAT" = "human" ]; then
  printf 'Syncing %d repositories with status checks.\n' "${#METADATA_ROWS[@]}"
fi

for row in "${METADATA_ROWS[@]}"; do
  IFS=$'\t' read -r repo fork_branch parent_repo parent_branch _archived <<< "$row"
  if [ -n "$BRANCH" ]; then
    fork_branch="$BRANCH"
    parent_branch="$BRANCH"
  fi

  if ! compare="$(compare_record "$repo" "$fork_branch" "$parent_repo" "$parent_branch")"; then
    compare_status=1
    message="$compare"
  elif ! parse_compare_record "$compare"; then
    compare_status=1
    message="$COMPARE_ERROR"
  else
    compare_status=0
    status="$PARSED_STATUS"
    behind="$PARSED_BEHIND"
    ahead="$PARSED_AHEAD"
    message=""
  fi

  if [ "$compare_status" -ne 0 ]; then
    failed=$((failed + 1))
    record_failure "$repo" "compare" "$message"
    if [ "$FORMAT" != "human" ]; then
      add_result "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "error" 0 0 "check" "error" "$message"
    elif [ "$STATUS_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
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
    if [ "$FORMAT" = "human" ]; then
      print_status_line "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead"
    else
      add_result "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead" "check" "$status" "status checked"
    fi
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if dry_run_action "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead"; then
      planned=$((planned + 1))
    else
      skipped=$((skipped + 1))
    fi
    if [ "$LAST_RESULT" = "blocked" ]; then
      blocked=$((blocked + 1))
    fi
    if [ "$FORMAT" != "human" ]; then
      add_result "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead" "$LAST_ACTION" "$LAST_RESULT" "$LAST_MESSAGE"
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
      blocked=$((blocked + 1))
      ;;
    *)
      failed=$((failed + 1))
      record_failure "$repo" "sync" "$LAST_MESSAGE"
      ;;
  esac
  if [ "$FORMAT" != "human" ]; then
    add_result "$repo" "$fork_branch" "$parent_repo" "$parent_branch" "$status" "$behind" "$ahead" "$LAST_ACTION" "$LAST_RESULT" "$LAST_MESSAGE"
  fi
done

if [ "$FORMAT" = "json" ]; then
  render_json
elif [ "$FORMAT" = "tsv" ]; then
  render_tsv
elif [ "$STATUS_ONLY" -eq 1 ]; then
  printf '\nSummary: %d identical, %d behind, %d ahead, %d diverged, %d failed.\n' \
    "$identical_count" "$behind_count" "$ahead_count" "$diverged_count" "$failed"
elif [ "$DRY_RUN" -eq 1 ]; then
  printf '\nSummary: %d identical, %d behind, %d ahead, %d diverged; %d planned, %d blocked, %d failed.\n' \
    "$identical_count" "$behind_count" "$ahead_count" "$diverged_count" "$planned" "$blocked" "$failed"
else
  printf '\nSummary: %d identical, %d behind, %d ahead, %d diverged; %d succeeded, %d blocked, %d failed.\n' \
    "$identical_count" "$behind_count" "$ahead_count" "$diverged_count" "$success" "$blocked" "$failed"
fi

if [ "$failed" -gt 0 ]; then
  printf 'Failed repositories:\n' >&2
  for failed_record in "${FAILED_REPOS[@]}"; do
    jq -r '"  \(.repo)\t\(.phase)\t\(.message)"' <<< "$failed_record" >&2
  done
  exit 1
fi

if [ "$blocked" -gt 0 ] && [ "$STATUS_ONLY" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  exit 2
fi
