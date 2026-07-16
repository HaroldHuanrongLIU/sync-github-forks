#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/sync_github_forks.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'expected output to contain: %s\n' "$needle" >&2
    printf 'actual output:\n%s\n' "$haystack" >&2
    return 1
  fi
}

assert_log_contains() {
  local log_file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$log_file"; then
    printf 'expected gh log to contain: %s\n' "$needle" >&2
    printf 'actual gh log:\n' >&2
    sed -n '1,240p' "$log_file" >&2
    return 1
  fi
}

write_fake_gh() {
  local bin_dir="$1"
  cat > "$bin_dir/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$GH_LOG"

state_file() {
  printf '%s/%s\n' "$GH_STATE_DIR" "$1"
}

metadata_for() {
  local owner="$1"
  local name="$2"
  case "$owner/$name" in
    owner/behind)
      printf 'owner/behind\tmain\tupstream/behind\tmain\n'
      ;;
    owner/diverged)
      printf 'owner/diverged\tmain\tupstream/diverged\tmain\n'
      ;;
    owner/mismatch)
      printf 'owner/mismatch\tmaster\tupstream/mismatch\tmain\n'
      ;;
    owner/force-mismatch)
      printf 'owner/force-mismatch\tmain\tupstream/force-mismatch\tstaging\n'
      ;;
    owner/transient)
      printf 'owner/transient\tmain\tupstream/transient\tmain\n'
      ;;
    owner/branch)
      printf 'owner/branch\tmain\tupstream/branch\tmain\n'
      ;;
    owner/metadata-error)
      printf 'metadata lookup failed\nsecond metadata line\n' >&2
      exit 1
      ;;
    owner/compare-error)
      printf 'owner/compare-error\tmain\tupstream/compare-error\tmain\n'
      ;;
    owner/sync-error)
      printf 'owner/sync-error\tmain\tupstream/sync-error\tmain\n'
      ;;
    owner/sync-success)
      printf 'owner/sync-success\tmain\tupstream/sync-success\tmain\n'
      ;;
    owner/ahead)
      printf 'owner/ahead\tmain\tupstream/ahead\tmain\n'
      ;;
    owner/archived)
      printf 'owner/archived\tmain\tupstream/archived\tmain\ttrue\n'
      ;;
    owner/invalid-status)
      printf 'owner/invalid-status\tmain\tupstream/invalid-status\tmain\n'
      ;;
    owner/invalid-count)
      printf 'owner/invalid-count\tmain\tupstream/invalid-count\tmain\n'
      ;;
    owner/verify-retry)
      printf 'owner/verify-retry\tmain\tupstream/verify-retry\tmain\n'
      ;;
    *)
      printf 'unknown repository: %s/%s\n' "$owner" "$name" >&2
      exit 1
      ;;
  esac
}

compare_for() {
  local path="$1"
  case "$path" in
    repos/upstream/behind/compare/main...owner:main)
      printf 'behind\t5\t0\n'
      ;;
    repos/upstream/diverged/compare/main...owner:main)
      printf 'diverged\t2\t1\n'
      ;;
    repos/upstream/mismatch/compare/main...owner:master)
      if [[ -f "$(state_file mismatch_synced)" ]]; then
        printf 'identical\t0\t0\n'
      else
        printf 'behind\t3\t0\n'
      fi
      ;;
    repos/upstream/force-mismatch/compare/staging...owner:main)
      if [[ -f "$(state_file force_mismatch_synced)" ]]; then
        printf 'identical\t0\t0\n'
      else
        printf 'diverged\t4\t2\n'
      fi
      ;;
    repos/upstream/transient/compare/main...owner:main)
      if [[ -f "$(state_file transient_synced)" ]]; then
        printf 'identical\t0\t0\n'
      else
        printf 'behind\t6\t0\n'
      fi
      ;;
    repos/upstream/branch/compare/main...owner:main)
      printf 'identical\t0\t0\n'
      ;;
    repos/upstream/branch/compare/dev...owner:dev)
      if [[ -f "$(state_file branch_synced)" ]]; then
        printf 'identical\t0\t0\n'
      else
        printf 'behind\t1\t0\n'
      fi
      ;;
    repos/upstream/compare-error/compare/main...owner:main)
      printf 'compare failed\tbad detail\nsecond compare line\n' >&2
      exit 1
      ;;
    repos/upstream/sync-error/compare/main...owner:main)
      printf 'behind\t2\t0\n'
      ;;
    repos/upstream/sync-success/compare/main...owner:main)
      if [[ -f "$(state_file sync_success_synced)" ]]; then
        printf 'identical\t0\t0\n'
      else
        printf 'behind\t1\t0\n'
      fi
      ;;
    repos/upstream/ahead/compare/main...owner:main)
      printf 'ahead\t0\t4\n'
      ;;
    repos/upstream/archived/compare/main...owner:main)
      printf 'identical\t0\t0\n'
      ;;
    repos/upstream/invalid-status/compare/main...owner:main)
      printf 'mystery\t0\t0\n'
      ;;
    repos/upstream/invalid-count/compare/main...owner:main)
      printf 'behind\tmany\t0\n'
      ;;
    repos/upstream/verify-retry/compare/main...owner:main)
      if [[ ! -f "$(state_file verify_retry_synced)" ]]; then
        printf 'behind\t2\t0\n'
      else
        checks_file="$(state_file verify_retry_checks)"
        checks=0
        [[ -f "$checks_file" ]] && checks="$(cat "$checks_file")"
        checks=$((checks + 1))
        printf '%s\n' "$checks" > "$checks_file"
        if [[ "$checks" -eq 1 ]]; then
          printf 'behind\t1\t0\n'
        else
          printf 'identical\t0\t0\n'
        fi
      fi
      ;;
    *)
      printf 'unknown compare path: %s\n' "$path" >&2
      exit 1
      ;;
  esac
}

list_page_for() {
  local owner="$1"
  local end_cursor="$2"
  local scenario="${GH_LIST_SCENARIO:-retry}"

  [[ "$owner" == "owner" ]] || {
    printf 'unknown owner: %s\n' "$owner" >&2
    exit 1
  }

  if [[ "$scenario" == "empty" ]]; then
    printf '%s\n' '{"data":{"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
    return
  fi

  if [[ "$scenario" == "archived" ]]; then
    printf '%s\n' '{"data":{"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"nameWithOwner":"owner/behind","isArchived":false,"defaultBranchRef":{"name":"main"},"parent":{"nameWithOwner":"upstream/behind","defaultBranchRef":{"name":"main"}}},{"nameWithOwner":"owner/archived","isArchived":true,"defaultBranchRef":{"name":"main"},"parent":{"nameWithOwner":"upstream/archived","defaultBranchRef":{"name":"main"}}}]}}}}'
    return
  fi

  if [[ -z "$end_cursor" ]]; then
    printf '%s\n' '{"data":{"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"},"nodes":[{"nameWithOwner":"owner/behind","isArchived":false,"defaultBranchRef":{"name":"main"},"parent":{"nameWithOwner":"upstream/behind","defaultBranchRef":{"name":"main"}}}]}}}}'
    return
  fi

  [[ "$end_cursor" == "cursor-1" ]] || {
    printf 'unknown cursor: %s\n' "$end_cursor" >&2
    exit 1
  }

  case "$scenario" in
    retry)
      attempts_file="$(state_file list_page_2_attempts)"
      attempts=0
      [[ -f "$attempts_file" ]] && attempts="$(cat "$attempts_file")"
      attempts=$((attempts + 1))
      printf '%s\n' "$attempts" > "$attempts_file"
      if [[ "$attempts" -eq 1 ]]; then
        printf '<html>temporary gateway response</html>\n'
        return
      fi
      ;;
    permanent)
      printf 'Post "https://api.github.com/graphql": EOF\n' >&2
      exit 1
      ;;
  esac

  printf '%s\n' '{"data":{"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"nameWithOwner":"owner/diverged","isArchived":false,"defaultBranchRef":{"name":"main"},"parent":{"nameWithOwner":"upstream/diverged","defaultBranchRef":{"name":"main"}}}]}}}}'
}

if [[ "$1" == "--version" ]]; then
  printf 'gh version test\n'
  exit 0
fi

if [[ "$1" == "auth" && "$2" == "status" ]]; then
  if [[ "${GH_AUTH_FAIL:-0}" -eq 1 ]]; then
    printf 'authentication failed\n' >&2
    exit 1
  fi
  exit 0
fi

if [[ "$1" == "api" ]]; then
  shift
  if [[ "${1:-}" == "user" ]]; then
    if [[ "${GH_OWNER_FAIL:-0}" -eq 1 ]]; then
      printf 'owner lookup failed\n' >&2
      exit 1
    fi
    printf 'owner\n'
    exit 0
  fi

  if [[ "${1:-}" == "graphql" ]]; then
    owner=""
    name=""
    end_cursor=""
    paginate=0
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        -f)
          case "$2" in
            owner=*) owner="${2#owner=}" ;;
            name=*) name="${2#name=}" ;;
            endCursor=*) end_cursor="${2#endCursor=}" ;;
          esac
          shift 2
          ;;
        --paginate)
          paginate=1
          shift
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ -n "$name" ]]; then
      metadata_for "$owner" "$name"
    elif [[ "$paginate" -eq 1 ]]; then
      case "${GH_LIST_SCENARIO:-retry}" in
        permanent)
          printf 'Post "https://api.github.com/graphql": EOF\n' >&2
          ;;
        *)
          printf "invalid character '<' looking for beginning of value\n" >&2
          ;;
      esac
      exit 1
    else
      list_page_for "$owner" "$end_cursor"
    fi
    exit 0
  fi

  if [[ "${1:-}" == "-X" && "${2:-}" == "PATCH" ]]; then
    ref_path="$3"
    force=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        -F)
          case "$2" in
            force=*) force="${2#force=}" ;;
          esac
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    case "$ref_path:$force" in
      repos/owner/mismatch/git/refs/heads/master:false)
        : > "$(state_file mismatch_synced)"
        printf '{"ref":"refs/heads/master"}\n'
        ;;
      repos/owner/force-mismatch/git/refs/heads/main:true)
        : > "$(state_file force_mismatch_synced)"
        printf '{"ref":"refs/heads/main"}\n'
        ;;
      *)
        printf 'unexpected patch: %s force=%s\n' "$ref_path" "$force" >&2
        exit 1
        ;;
    esac
    exit 0
  fi

  if [[ "${1:-}" == repos/upstream/*/branches/* ]]; then
    case "$1" in
      repos/upstream/mismatch/branches/main)
        printf 'sha-mismatch\n'
        ;;
      repos/upstream/force-mismatch/branches/staging)
        printf 'sha-force-mismatch\n'
        ;;
      *)
        printf 'unknown branch path: %s\n' "$1" >&2
        exit 1
        ;;
    esac
    exit 0
  fi

  compare_for "$1"
  exit 0
fi

if [[ "$1" == "repo" && "$2" == "sync" ]]; then
  repo="$3"
  case "$repo" in
    owner/transient)
      attempts_file="$(state_file transient_attempts)"
      attempts=0
      [[ -f "$attempts_file" ]] && attempts="$(cat "$attempts_file")"
      attempts=$((attempts + 1))
      printf '%s\n' "$attempts" > "$attempts_file"
      if [[ "$attempts" -eq 1 ]]; then
        printf 'Post "https://api.github.com/graphql": EOF\n' >&2
        exit 1
      fi
      : > "$(state_file transient_synced)"
      ;;
    owner/behind)
      ;;
    owner/diverged)
      if [[ "$*" == *"--force"* ]]; then
        :
      else
        printf "can't sync because there are diverging changes; use \`--force\` to overwrite the destination branch\n" >&2
        exit 1
      fi
      ;;
    owner/force-mismatch)
      ;;
    owner/branch)
      if [[ "$*" != *"--branch dev"* ]]; then
        printf 'expected branch sync with --branch dev\n' >&2
        exit 1
      fi
      : > "$(state_file branch_synced)"
      ;;
    owner/sync-error)
      printf 'sync failed\tbad detail\n' >&2
      exit 1
      ;;
    owner/sync-success)
      : > "$(state_file sync_success_synced)"
      ;;
    owner/verify-retry)
      : > "$(state_file verify_retry_synced)"
      ;;
    *)
      ;;
  esac
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
FAKE_GH
  chmod +x "$bin_dir/gh"
}

run_with_fake_gh() {
  local test_name="$1"
  shift
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/state"
  write_fake_gh "$tmp_dir/bin"
  GH_LOG="$tmp_dir/gh.log" GH_STATE_DIR="$tmp_dir/state" PATH="$tmp_dir/bin:$PATH" "$@"
  rm -rf "$tmp_dir"
  printf 'ok - %s\n' "$test_name"
}

test_status_reports_behind_and_diverged_without_syncing() {
  run_with_fake_gh "status reports behind and diverged without syncing" bash -c '
    set -euo pipefail
    output="$("$1" --status --repo owner/behind --repo owner/diverged)"
    [[ "$(grep -c "repo sync" "$GH_LOG" || true)" -eq 0 ]]
    [[ "$output" == *"owner/behind"* ]]
    [[ "$output" == *"behind=5"* ]]
    [[ "$output" == *"status=behind"* ]]
    [[ "$output" == *"owner/diverged"* ]]
    [[ "$output" == *"ahead=1"* ]]
    [[ "$output" == *"status=diverged"* ]]
  ' _ "$SCRIPT"
}

test_execute_fast_forwards_branch_mismatch_without_force() {
  run_with_fake_gh "execute fast-forwards branch mismatch without force" bash -c '
    set -euo pipefail
    output="$("$1" --execute --repo owner/mismatch)"
    [[ "$output" == *"Summary: 0 identical, 1 behind, 0 ahead, 0 diverged; 1 succeeded, 0 blocked, 0 failed."* ]]
    grep -Fq "api repos/upstream/mismatch/compare/main...owner:master" "$GH_LOG"
    grep -Fq "api -X PATCH repos/owner/mismatch/git/refs/heads/master" "$GH_LOG"
    grep -Fq "force=false" "$GH_LOG"
  ' _ "$SCRIPT"
}

test_force_resets_branch_mismatch_and_verifies() {
  run_with_fake_gh "force resets branch mismatch and verifies" bash -c '
    set -euo pipefail
    output="$("$1" --execute --force --repo owner/force-mismatch)"
    [[ "$output" == *"Summary: 0 identical, 0 behind, 0 ahead, 1 diverged; 1 succeeded, 0 blocked, 0 failed."* ]]
    grep -Fq "api -X PATCH repos/owner/force-mismatch/git/refs/heads/main" "$GH_LOG"
    grep -Fq "force=true" "$GH_LOG"
    [[ "$output" == *"verified identical"* ]]
  ' _ "$SCRIPT"
}

test_execute_retries_transient_eof_sync_failure() {
  run_with_fake_gh "execute retries transient EOF sync failure" bash -c '
    set -euo pipefail
    "$1" --execute --repo owner/transient >"$GH_STATE_DIR/stdout" 2>"$GH_STATE_DIR/stderr"
    output="$(cat "$GH_STATE_DIR/stdout")"
    error_output="$(cat "$GH_STATE_DIR/stderr")"
    [[ "$output" != *"retrying after transient GitHub API error"* ]]
    [[ "$error_output" == *"retrying after transient GitHub API error"* ]]
    [[ "$(grep -c "repo sync owner/transient" "$GH_LOG")" -eq 2 ]]
    [[ "$output" == *"Summary: 0 identical, 1 behind, 0 ahead, 0 diverged; 1 succeeded, 0 blocked, 0 failed."* ]]
  ' _ "$SCRIPT"
}

test_execute_uses_requested_branch_for_compare_and_sync() {
  run_with_fake_gh "execute uses requested branch for compare and sync" bash -c '
    set -euo pipefail
    output="$("$1" --execute --branch dev --repo owner/branch)"
    [[ "$output" == *"Summary: 0 identical, 1 behind, 0 ahead, 0 diverged; 1 succeeded, 0 blocked, 0 failed."* ]]
    grep -Fq "api repos/upstream/branch/compare/dev...owner:dev" "$GH_LOG"
    grep -Fq "repo sync owner/branch --branch dev" "$GH_LOG"
  ' _ "$SCRIPT"
}

test_execute_aborts_when_later_page_exhausts_retries() {
  run_with_fake_gh "execute aborts when later page exhausts retries" bash -c '
    set -euo pipefail
    export GH_LIST_SCENARIO=permanent
    set +e
    "$1" --execute --owner owner --format json >"$GH_STATE_DIR/stdout" 2>"$GH_STATE_DIR/stderr"
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    [[ ! -s "$GH_STATE_DIR/stdout" ]]
    [[ "$(grep -c "repo sync" "$GH_LOG" || true)" -eq 0 ]]
    [[ "$(grep -c "api -X PATCH" "$GH_LOG" || true)" -eq 0 ]]
  ' _ "$SCRIPT"
}

test_enumeration_retries_only_failed_page() {
  run_with_fake_gh "enumeration retries only failed page" bash -c '
    set -euo pipefail
    export GH_LIST_SCENARIO=retry
    "$1" --status --owner owner >"$GH_STATE_DIR/stdout" 2>"$GH_STATE_DIR/stderr"
    output="$(cat "$GH_STATE_DIR/stdout")"
    error_output="$(cat "$GH_STATE_DIR/stderr")"
    [[ "$output" == *"owner/behind"* ]]
    [[ "$output" == *"owner/diverged"* ]]
    [[ "$error_output" == *"retrying after transient GitHub API error"* ]]
    [[ "$(grep -c "repositoryOwner" "$GH_LOG")" -eq 3 ]]
    [[ "$(grep -c "endCursor=cursor-1" "$GH_LOG")" -eq 2 ]]
  ' _ "$SCRIPT"
}

test_invalid_format_fails_without_stdout() {
  run_with_fake_gh "invalid format fails without stdout" bash -c '
    set -euo pipefail
    set +e
    "$1" --status --repo owner/behind --format xml >"$GH_STATE_DIR/stdout" 2>"$GH_STATE_DIR/stderr"
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    [[ ! -s "$GH_STATE_DIR/stdout" ]]
    grep -Fq -- "--format must be one of: human, tsv, json" "$GH_STATE_DIR/stderr"
  ' _ "$SCRIPT"
}

test_json_status_matches_schema() {
  run_with_fake_gh "json status matches schema" bash -c '
    set -euo pipefail
    output="$("$1" --status --repo owner/behind --repo owner/diverged --format json)"
    jq -e ".repositories | length == 2" <<< "$output" >/dev/null
    jq -e ".repositories[0] == {
      \"type\": \"repository\",
      \"repo\": \"owner/behind\",
      \"fork_branch\": \"main\",
      \"upstream\": \"upstream/behind\",
      \"upstream_branch\": \"main\",
      \"status\": \"behind\",
      \"behind\": 5,
      \"ahead\": 0,
      \"action\": \"check\",
      \"result\": \"behind\",
      \"message\": \"status checked\"
    }" <<< "$output" >/dev/null
    jq -e ".summary == {
      \"mode\": \"status\",
      \"checked\": 2,
      \"identical\": 0,
      \"behind\": 1,
      \"ahead\": 0,
      \"diverged\": 1,
      \"failed\": 0,
      \"planned\": 0,
      \"succeeded\": 0,
      \"blocked\": 0
    }" <<< "$output" >/dev/null
  ' _ "$SCRIPT"
}

test_tsv_status_matches_schema() {
  run_with_fake_gh "tsv status matches schema" bash -c '
    set -euo pipefail
    output="$("$1" --status --repo owner/behind --format tsv)"
    header="$(sed -n "1p" <<< "$output")"
    repository_row="$(sed -n "2p" <<< "$output")"
    summary_row="$(sed -n "3p" <<< "$output")"
    [[ "$header" == $'"'"'type\trepo\tfork_branch\tupstream\tupstream_branch\tstatus\tbehind\tahead\taction\tresult\tmessage\tmode\tchecked\tidentical_count\tbehind_count\tahead_count\tdiverged_count\tfailed_count\tplanned_count\tsucceeded_count\tblocked_count'"'"' ]]
    [[ "$repository_row" == $'"'"'repository\towner/behind\tmain\tupstream/behind\tmain\tbehind\t5\t0\tcheck\tbehind\tstatus checked'"'"'* ]]
    [[ "$summary_row" == $'"'"'summary\t'"'"'* ]]
    [[ "$summary_row" == *$'"'"'\tstatus\t1\t0\t1\t0\t0\t0\t0\t0\t0'"'"' ]]
    [[ "$(wc -l <<< "$output" | tr -d " ")" -eq 3 ]]
  ' _ "$SCRIPT"
}

test_empty_enumeration_emits_structured_summary() {
  run_with_fake_gh "empty enumeration emits structured summary" bash -c '
    set -euo pipefail
    export GH_LIST_SCENARIO=empty
    json_output="$("$1" --status --owner owner --format json)"
    jq -e ".repositories == [] and .summary.checked == 0 and .summary.failed == 0" <<< "$json_output" >/dev/null

    tsv_output="$("$1" --status --owner owner --format tsv)"
    [[ "$(wc -l <<< "$tsv_output" | tr -d " ")" -eq 2 ]]
    [[ "$(sed -n "1p" <<< "$tsv_output")" == type$'"'"'\t'"'"'repo$'"'"'\t'"'"'* ]]
    [[ "$(sed -n "2p" <<< "$tsv_output")" == summary$'"'"'\t'"'"'* ]]
  ' _ "$SCRIPT"
}

test_early_auth_and_owner_failures_emit_no_stdout() {
  run_with_fake_gh "early auth and owner failures emit no stdout" bash -c '
    set -euo pipefail
    export GH_AUTH_FAIL=1
    set +e
    "$1" --status --format json >"$GH_STATE_DIR/auth-stdout" 2>"$GH_STATE_DIR/auth-stderr"
    auth_status=$?
    set -e
    [[ "$auth_status" -eq 1 ]]
    [[ ! -s "$GH_STATE_DIR/auth-stdout" ]]
    grep -Fq "authentication failed" "$GH_STATE_DIR/auth-stderr"

    unset GH_AUTH_FAIL
    export GH_OWNER_FAIL=1
    set +e
    "$1" --status --format json >"$GH_STATE_DIR/owner-stdout" 2>"$GH_STATE_DIR/owner-stderr"
    owner_status=$?
    set -e
    [[ "$owner_status" -eq 1 ]]
    [[ ! -s "$GH_STATE_DIR/owner-stdout" ]]
    grep -Fq "failed to determine authenticated GitHub user" "$GH_STATE_DIR/owner-stderr"
  ' _ "$SCRIPT"
}

test_missing_jq_fails_with_empty_structured_stdout() {
  run_with_fake_gh "missing jq fails with empty structured stdout" bash -c '
    set -euo pipefail
    isolated_path="${GH_STATE_DIR%/state}/bin"
    set +e
    PATH="$isolated_path" /bin/bash "$1" --status --format json >"$GH_STATE_DIR/stdout" 2>"$GH_STATE_DIR/stderr"
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    [[ ! -s "$GH_STATE_DIR/stdout" ]]
    grep -Fq "jq is not installed or not on PATH" "$GH_STATE_DIR/stderr"
  ' _ "$SCRIPT"
}

test_explicit_metadata_failure_is_an_error_record() {
  run_with_fake_gh "explicit metadata failure is an error record" bash -c '
    set -euo pipefail
    set +e
    output="$("$1" --status --repo owner/metadata-error --repo owner/behind --format json 2>"$GH_STATE_DIR/stderr")"
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    jq -e ".repositories | length == 2" <<< "$output" >/dev/null
    jq -e "any(.repositories[]; .repo == \"owner/metadata-error\" and .status == \"error\" and .action == \"check\" and .result == \"error\" and (.message | contains(\"metadata lookup failed\")) and (.message | contains(\"second metadata line\")))" <<< "$output" >/dev/null
    jq -e ".summary.checked == 2 and .summary.failed == 1 and .summary.behind == 1" <<< "$output" >/dev/null
  ' _ "$SCRIPT"
}

test_compare_error_is_structured_and_later_repo_continues() {
  run_with_fake_gh "compare error is structured and later repo continues" bash -c '
    set -euo pipefail
    set +e
    json_output="$("$1" --status --repo owner/compare-error --repo owner/behind --format json 2>"$GH_STATE_DIR/json-stderr")"
    json_status=$?
    set -e
    [[ "$json_status" -eq 1 ]]
    jq -e ".repositories | length == 2" <<< "$json_output" >/dev/null
    jq -e "any(.repositories[]; .repo == \"owner/compare-error\" and .status == \"error\" and .result == \"error\" and (.message | contains(\"compare failed\")) and (.message | contains(\"second compare line\")))" <<< "$json_output" >/dev/null
    jq -e "any(.repositories[]; .repo == \"owner/behind\" and .status == \"behind\")" <<< "$json_output" >/dev/null
    jq -e ".summary.failed == 1 and .summary.behind == 1" <<< "$json_output" >/dev/null

    set +e
    tsv_output="$("$1" --status --repo owner/compare-error --format tsv 2>"$GH_STATE_DIR/tsv-stderr")"
    tsv_status=$?
    set -e
    [[ "$tsv_status" -eq 1 ]]
    message="$(awk -F "\t" '"'"'$2 == "owner/compare-error" { print $11 }'"'"' <<< "$tsv_output")"
    [[ "$message" == "compare failed bad detail second compare line" ]]
  ' _ "$SCRIPT"
}

test_sync_error_is_structured_and_later_repo_continues() {
  run_with_fake_gh "sync error is structured and later repo continues" bash -c '
    set -euo pipefail
    set +e
    output="$("$1" --execute --repo owner/sync-error --repo owner/sync-success --format json 2>"$GH_STATE_DIR/stderr")"
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    jq -e ".repositories | length == 2" <<< "$output" >/dev/null
    jq -e "any(.repositories[]; .repo == \"owner/sync-error\" and .status == \"behind\" and .action == \"sync\" and .result == \"error\" and (.message | contains(\"sync failed\")))" <<< "$output" >/dev/null
    jq -e "any(.repositories[]; .repo == \"owner/sync-success\" and .result == \"succeeded\" and .message == \"verified identical\")" <<< "$output" >/dev/null
    jq -e ".summary.failed == 1 and .summary.succeeded == 1 and .summary.behind == 2" <<< "$output" >/dev/null
    [[ "$(grep -c "repo sync owner/sync-" "$GH_LOG")" -eq 2 ]]
  ' _ "$SCRIPT"
}

test_status_divergence_exits_zero() {
  run_with_fake_gh "status divergence exits zero" bash -c '
    set -euo pipefail
    output="$("$1" --status --repo owner/diverged --format json)"
    jq -e ".repositories[0].result == \"diverged\"" <<< "$output" >/dev/null
    jq -e ".summary.diverged == 1 and .summary.failed == 0 and .summary.blocked == 0" <<< "$output" >/dev/null
  ' _ "$SCRIPT"
}

test_dry_run_divergence_exits_two() {
  run_with_fake_gh "dry run divergence exits two" bash -c '
    set -euo pipefail
    set +e
    output="$("$1" --dry-run --repo owner/diverged --format json)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]]
    jq -e ".repositories[0].result == \"blocked\"" <<< "$output" >/dev/null
    jq -e ".summary.blocked == 1 and .summary.diverged == 1 and .summary.failed == 0" <<< "$output" >/dev/null
  ' _ "$SCRIPT"
}

test_execute_divergence_exits_two_without_writing() {
  run_with_fake_gh "execute divergence exits two without writing" bash -c '
    set -euo pipefail
    set +e
    output="$("$1" --execute --repo owner/diverged --format json 2>"$GH_STATE_DIR/stderr")"
    status=$?
    set -e
    [[ "$status" -eq 2 ]]
    jq -e ".repositories[0].result == \"blocked\"" <<< "$output" >/dev/null
    jq -e ".summary.blocked == 1 and .summary.diverged == 1 and .summary.failed == 0" <<< "$output" >/dev/null
    [[ "$(grep -c "repo sync owner/diverged" "$GH_LOG" || true)" -eq 0 ]]
    [[ "$(grep -c "api -X PATCH repos/owner/diverged" "$GH_LOG" || true)" -eq 0 ]]
  ' _ "$SCRIPT"
}

test_operational_error_takes_precedence_over_divergence() {
  run_with_fake_gh "operational error takes precedence over divergence" bash -c '
    set -euo pipefail
    set +e
    output="$("$1" --dry-run --repo owner/diverged --repo owner/compare-error --format json 2>"$GH_STATE_DIR/stderr")"
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    jq -e ".summary.blocked == 1 and .summary.diverged == 1 and .summary.failed == 1" <<< "$output" >/dev/null
  ' _ "$SCRIPT"
}

test_ahead_is_skipped_without_writing_and_exits_zero() {
  run_with_fake_gh "ahead is skipped without writing and exits zero" bash -c '
    set -euo pipefail
    output="$("$1" --execute --repo owner/ahead --format json)"
    jq -e ".repositories[0].result == \"ahead\" and .summary.ahead == 1 and .summary.failed == 0" <<< "$output" >/dev/null
    [[ "$(grep -c "repo sync owner/ahead" "$GH_LOG" || true)" -eq 0 ]]
    [[ "$(grep -c "api -X PATCH repos/owner/ahead" "$GH_LOG" || true)" -eq 0 ]]
  ' _ "$SCRIPT"
}

test_owner_enumeration_excludes_archived_by_default() {
  run_with_fake_gh "owner enumeration excludes archived by default" bash -c '
    set -euo pipefail
    export GH_LIST_SCENARIO=archived
    default_output="$("$1" --status --owner owner --format json)"
    jq -e "[.repositories[].repo] == [\"owner/behind\"]" <<< "$default_output" >/dev/null

    included_output="$("$1" --status --owner owner --include-archived --format json)"
    jq -e "[.repositories[].repo] == [\"owner/behind\", \"owner/archived\"]" <<< "$included_output" >/dev/null
  ' _ "$SCRIPT"
}

test_explicit_archived_repo_is_still_processed() {
  run_with_fake_gh "explicit archived repo is still processed" bash -c '
    set -euo pipefail
    output="$("$1" --status --repo owner/archived --format json)"
    jq -e ".repositories[0].repo == \"owner/archived\" and .repositories[0].status == \"identical\"" <<< "$output" >/dev/null
  ' _ "$SCRIPT"
}

test_human_summary_separates_classifications() {
  run_with_fake_gh "human summary separates classifications" bash -c '
    set -euo pipefail
    set +e
    output="$("$1" --dry-run --repo owner/behind --repo owner/ahead --repo owner/diverged)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"Summary: 0 identical, 1 behind, 1 ahead, 1 diverged; 1 planned, 1 blocked, 0 failed."* ]]
  ' _ "$SCRIPT"
}

test_malformed_compare_records_are_operational_errors() {
  run_with_fake_gh "malformed compare records are operational errors" bash -c '
    set -euo pipefail
    set +e
    output="$("$1" --status --repo owner/invalid-status --repo owner/invalid-count --repo owner/behind --format json 2>"$GH_STATE_DIR/stderr")"
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    jq -e ".repositories | length == 3" <<< "$output" >/dev/null
    jq -e "[.repositories[] | select(.status == \"error\")] | length == 2" <<< "$output" >/dev/null
    jq -e "all(.repositories[] | select(.repo == \"owner/invalid-status\" or .repo == \"owner/invalid-count\"); .result == \"error\" and (.message | contains(\"invalid compare response\")))" <<< "$output" >/dev/null
    jq -e "any(.repositories[]; .repo == \"owner/behind\" and .status == \"behind\")" <<< "$output" >/dev/null
    jq -e ".summary.checked == 3 and .summary.failed == 2 and .summary.behind == 1" <<< "$output" >/dev/null
  ' _ "$SCRIPT"
}

test_verification_retry_diagnostic_uses_stderr() {
  run_with_fake_gh "verification retry diagnostic uses stderr" bash -c '
    set -euo pipefail
    "$1" --execute --repo owner/verify-retry --format json >"$GH_STATE_DIR/stdout" 2>"$GH_STATE_DIR/stderr"
    output="$(cat "$GH_STATE_DIR/stdout")"
    error_output="$(cat "$GH_STATE_DIR/stderr")"
    jq -e ".repositories[0].result == \"succeeded\" and .repositories[0].message == \"verified identical\"" <<< "$output" >/dev/null
    [[ "$error_output" == *"verification shows repository still behind"* ]]
  ' _ "$SCRIPT"
}

test_status_reports_behind_and_diverged_without_syncing
test_execute_fast_forwards_branch_mismatch_without_force
test_force_resets_branch_mismatch_and_verifies
test_execute_retries_transient_eof_sync_failure
test_execute_uses_requested_branch_for_compare_and_sync
test_execute_aborts_when_later_page_exhausts_retries
test_enumeration_retries_only_failed_page
test_invalid_format_fails_without_stdout
test_json_status_matches_schema
test_tsv_status_matches_schema
test_empty_enumeration_emits_structured_summary
test_early_auth_and_owner_failures_emit_no_stdout
test_missing_jq_fails_with_empty_structured_stdout
test_explicit_metadata_failure_is_an_error_record
test_compare_error_is_structured_and_later_repo_continues
test_sync_error_is_structured_and_later_repo_continues
test_status_divergence_exits_zero
test_dry_run_divergence_exits_two
test_execute_divergence_exits_two_without_writing
test_operational_error_takes_precedence_over_divergence
test_ahead_is_skipped_without_writing_and_exits_zero
test_owner_enumeration_excludes_archived_by_default
test_explicit_archived_repo_is_still_processed
test_human_summary_separates_classifications
test_malformed_compare_records_are_operational_errors
test_verification_retry_diagnostic_uses_stderr
