# Sync Forks Reliability Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:test-driven-development while executing these tightly coupled Bash changes. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make fork enumeration and output reliable under transient GitHub API failures while preserving existing synchronization safety.

**Architecture:** Keep the single Bash entry point. Add a cursor-based metadata page fetcher, collect normalized per-repository result rows, and render them through human, TSV, or JSON output paths. Existing compare and synchronization helpers remain authoritative.

**Tech Stack:** Bash, GitHub CLI, jq, fake-`gh` shell tests.

---

## Chunk 1: Retry and pagination

### Task 1: Keep retry diagnostics off stdout

**Files:**
- Modify: `tests/sync_github_forks_test.sh`
- Modify: `scripts/sync_github_forks.sh`

- [ ] Add `test_retry_diagnostic_uses_stderr_without_polluting_stdout`.
- [ ] Run `bash tests/sync_github_forks_test.sh`.
      Expected: FAIL because stdout contains `retrying after transient GitHub API error`.
- [ ] Change only the retry diagnostic stream.
- [ ] Run `bash tests/sync_github_forks_test.sh`.
      Expected: PASS.

### Task 2: Retry only the failed GraphQL page

**Files:**
- Modify: `scripts/sync_github_forks.sh`
- Test: `tests/sync_github_forks_test.sh`

- [ ] Extend fake GraphQL enumeration with two cursor pages. Make page two
      return successful HTML once, then valid JSON.
- [ ] Add `test_enumeration_retries_only_failed_page`.
- [ ] Add `test_execute_aborts_when_later_page_exhausts_retries`, configure
      fake page two to fail permanently, and assert exit 1, empty stdout, and
      no `repo sync` or refs PATCH log entry.
- [ ] Run `bash tests/sync_github_forks_test.sh`.
      Expected: the failed-page retry test FAILS because the current
      `--paginate` call cannot recover per page; the atomic-enumeration safety
      test PASSES on current code.
- [ ] Add the explicit cursor page fetcher and loop.
- [ ] Run `bash tests/sync_github_forks_test.sh`.
      Expected: both tests PASS, the fake log shows page one once and page two
      twice, and no production change beyond the cursor loop is made for the
      already-passing atomic-enumeration behavior.

## Chunk 2: Structured output and exit semantics

### Task 3: Add and validate the output formats

**Files:**
- Modify: `scripts/sync_github_forks.sh`
- Test: `tests/sync_github_forks_test.sh`

- [ ] Add `test_invalid_format_fails_without_stdout`, run
      `bash tests/sync_github_forks_test.sh`, and observe FAIL because
      `--format` is unknown.
- [ ] Add only `--format` parsing/validation, rerun the suite, and observe PASS.
- [ ] Add `test_json_status_matches_schema`, rerun the suite, and observe FAIL
      because JSON rendering is missing.
- [ ] Add normalized result rows plus JSON rendering, rerun, and observe PASS.
- [ ] Add `test_tsv_status_matches_header_and_sanitizes_messages`, rerun, and
      observe FAIL because TSV rendering is missing.
- [ ] Add TSV rendering and message sanitization, rerun, and observe PASS.

### Task 4: Cover empty and error output boundaries

**Files:**
- Modify: `scripts/sync_github_forks.sh`
- Test: `tests/sync_github_forks_test.sh`

- [ ] Add `test_empty_enumeration_emits_valid_json_and_tsv_summary`, run the
      suite, observe the unsupported empty document behavior, implement the
      smallest renderer change, and rerun to PASS.
- [ ] Add `test_early_auth_and_owner_failures_emit_no_stdout`, run the suite,
      observe the failing boundary, preserve stderr-only fatal diagnostics, and
      rerun to PASS.
- [ ] Add `test_missing_gh_or_jq_fails_with_empty_structured_stdout`, run the
      suite, and verify exit 1 plus the dependency diagnostic on stderr.
- [ ] Add `test_explicit_metadata_failure_is_an_error_record`, run the suite,
      observe FAIL, add metadata error result collection, and rerun to PASS.
- [ ] Add `test_compare_error_is_structured_and_later_repo_continues`, run the
      suite, observe FAIL, add compare error result collection, and rerun to
      PASS.
- [ ] Add `test_sync_error_is_structured_and_later_repo_continues`, run the
      suite, observe FAIL, add sync error result collection, and rerun to PASS.

### Task 5: Apply classification summaries and exit codes

**Files:**
- Modify: `scripts/sync_github_forks.sh`
- Test: `tests/sync_github_forks_test.sh`

- [ ] Add `test_status_divergence_exits_zero`; run the suite and keep it green
      as a characterization test.
- [ ] Add `test_dry_run_divergence_exits_two`; assert repository
      `result=blocked` and summary `blocked=1`, `diverged=1`, `failed=0`; run the
      suite and observe FAIL; implement the dry-run exit/summary behavior and
      rerun to PASS.
- [ ] Add `test_execute_divergence_exits_two_without_writing`; assert the same
      blocked record/counters and no sync/PATCH call; run the suite and observe
      FAIL; implement execute blocked semantics and rerun to PASS.
- [ ] Add `test_operational_error_takes_precedence_over_divergence`; run the
      suite and observe FAIL; implement error precedence and rerun to PASS.
- [ ] Add `test_ahead_is_skipped_without_writing_and_exits_zero`; assert no
      sync/PATCH call; run before and after the counter refactor and keep green.

### Task 6: Preserve archived scope

**Files:**
- Test: `tests/sync_github_forks_test.sh`

- [ ] Add `test_owner_enumeration_excludes_archived_by_default`.
- [ ] Add `test_explicit_archived_repo_is_still_processed`.
- [ ] Run `bash tests/sync_github_forks_test.sh`.
      Expected: PASS without production changes; if not, make the smallest
      correction consistent with the approved design.

## Chunk 3: Skill documentation and verification

### Task 7: Document and validate the updated skill

**Files:**
- Modify: `SKILL.md`
- Modify: `README.md`

- [ ] Document `--format`, cursor-page retry behavior, summaries, and exit codes.
- [ ] Remove or revise statements that imply `--paginate` or retry diagnostics on stdout.
- [ ] Run `bash -n scripts/sync_github_forks.sh`.
- [ ] Run `bash tests/sync_github_forks_test.sh`.
- [ ] Run
      `python3 /Users/haroldhuanrongliu/.codex/skills/.system/skill-creator/scripts/quick_validate.py .`.
      Expected: validation succeeds.
- [ ] Run `gh auth status`.
      Expected: authenticated `github.com` account.
- [ ] Run
      `scripts/sync_github_forks.sh --repo HaroldHuanrongLIU/llm-viz --dry-run --format json | jq -e '.repositories | length == 1'`.
      Expected: jq exits 0 and no remote write occurs.
- [ ] Inspect `git diff` and confirm only task-related files changed.
