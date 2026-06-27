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
    *)
      printf 'unknown compare path: %s\n' "$path" >&2
      exit 1
      ;;
  esac
}

if [[ "$1" == "--version" ]]; then
  printf 'gh version test\n'
  exit 0
fi

if [[ "$1" == "auth" && "$2" == "status" ]]; then
  exit 0
fi

if [[ "$1" == "api" ]]; then
  shift
  if [[ "${1:-}" == "user" ]]; then
    printf 'owner\n'
    exit 0
  fi

  if [[ "${1:-}" == "graphql" ]]; then
    owner=""
    name=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        -f)
          case "$2" in
            owner=*) owner="${2#owner=}" ;;
            name=*) name="${2#name=}" ;;
          esac
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    metadata_for "$owner" "$name"
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
    [[ "$output" == *"Summary: 1 succeeded, 0 skipped, 0 failed."* ]]
    grep -Fq "api repos/upstream/mismatch/compare/main...owner:master" "$GH_LOG"
    grep -Fq "api -X PATCH repos/owner/mismatch/git/refs/heads/master" "$GH_LOG"
    grep -Fq "force=false" "$GH_LOG"
  ' _ "$SCRIPT"
}

test_force_resets_branch_mismatch_and_verifies() {
  run_with_fake_gh "force resets branch mismatch and verifies" bash -c '
    set -euo pipefail
    output="$("$1" --execute --force --repo owner/force-mismatch)"
    [[ "$output" == *"Summary: 1 succeeded, 0 skipped, 0 failed."* ]]
    grep -Fq "api -X PATCH repos/owner/force-mismatch/git/refs/heads/main" "$GH_LOG"
    grep -Fq "force=true" "$GH_LOG"
    [[ "$output" == *"verified identical"* ]]
  ' _ "$SCRIPT"
}

test_execute_retries_transient_eof_sync_failure() {
  run_with_fake_gh "execute retries transient EOF sync failure" bash -c '
    set -euo pipefail
    output="$("$1" --execute --repo owner/transient)"
    [[ "$output" == *"retrying after transient GitHub API error"* ]]
    [[ "$(grep -c "repo sync owner/transient" "$GH_LOG")" -eq 2 ]]
    [[ "$output" == *"Summary: 1 succeeded, 0 skipped, 0 failed."* ]]
  ' _ "$SCRIPT"
}

test_execute_uses_requested_branch_for_compare_and_sync() {
  run_with_fake_gh "execute uses requested branch for compare and sync" bash -c '
    set -euo pipefail
    output="$("$1" --execute --branch dev --repo owner/branch)"
    [[ "$output" == *"Summary: 1 succeeded, 0 skipped, 0 failed."* ]]
    grep -Fq "api repos/upstream/branch/compare/dev...owner:dev" "$GH_LOG"
    grep -Fq "repo sync owner/branch --branch dev" "$GH_LOG"
  ' _ "$SCRIPT"
}

test_status_reports_behind_and_diverged_without_syncing
test_execute_fast_forwards_branch_mismatch_without_force
test_force_resets_branch_mismatch_and_verifies
test_execute_retries_transient_eof_sync_failure
test_execute_uses_requested_branch_for_compare_and_sync
