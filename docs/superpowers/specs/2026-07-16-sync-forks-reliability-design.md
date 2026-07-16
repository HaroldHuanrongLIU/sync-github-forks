# Sync Forks Reliability Design

## Scope

Improve the existing Bash workflow without changing its safety defaults or sync
mechanism. Keep dry-run as the default, preserve non-force behavior, and leave
archived repositories excluded during owner enumeration unless explicitly
requested. Preserve the current behavior that an explicit `--repo` target is
processed even when archived.

## Design

1. Send retry diagnostics to stderr so stdout remains valid status data.
2. Replace `gh api graphql --paginate` with an explicit cursor loop. Retry only
   the failed page and retain metadata from pages already fetched while retrying.
   If any page exhausts its retries, abort before execute mode writes to any
   repository; never process a partial enumeration.
3. Add `--format human|tsv|json`, defaulting to the current human-oriented
   output. TSV and JSON must contain only machine-readable data on stdout.
4. Track `identical`, `behind`, `ahead`, `diverged`, and operational errors
   separately.

Exit codes are:

| Mode | Operational error | Unforced divergence only | Otherwise |
| --- | --- | --- | --- |
| `--status` | 1 | 0 | 0 |
| `--dry-run` | 1 | 2 | 0 |
| `--execute` | 1 | 2 | 0 |

Operational errors take precedence over blocked divergence. With `--force`, a
divergent repository is planned or executed rather than blocked.

## Structured Output

Each repository record has these fields in this order for TSV and with these
names for JSON:

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | string | `repository`; the TSV summary row uses `summary` |
| `repo` | string | Fork `OWNER/REPO` |
| `fork_branch` | string | Compared destination branch |
| `upstream` | string | Parent `OWNER/REPO` |
| `upstream_branch` | string | Compared source branch |
| `status` | string | `identical`, `behind`, `ahead`, `diverged`, or `error` |
| `behind` | integer | Commits behind before the action |
| `ahead` | integer | Commits ahead before the action |
| `action` | string | `check`, `skip`, `sync`, `fast-forward`, `force-sync`, or `force-reset` |
| `result` | string | `identical`, `behind`, `ahead`, `diverged`, `planned`, `succeeded`, `blocked`, or `error` |
| `message` | string | Concise result or original operational error |

JSON is one document:

```json
{
  "repositories": [
    {
      "type": "repository",
      "repo": "owner/fork",
      "fork_branch": "main",
      "upstream": "upstream/project",
      "upstream_branch": "main",
      "status": "behind",
      "behind": 3,
      "ahead": 0,
      "action": "sync",
      "result": "planned",
      "message": "safe fast-forward"
    }
  ],
  "summary": {
    "mode": "dry-run",
    "checked": 1,
    "identical": 0,
    "behind": 1,
    "ahead": 0,
    "diverged": 0,
    "failed": 0,
    "planned": 1,
    "succeeded": 0,
    "blocked": 0
  }
}
```

TSV uses the repository field order above, then appends summary columns:
`mode`, `checked`, `identical_count`, `behind_count`, `ahead_count`,
`diverged_count`, `failed_count`, `planned_count`, `succeeded_count`, and
`blocked_count`. Repository rows leave summary columns empty. The final summary
row leaves repository-specific columns empty and fills the summary columns.
Tabs, carriage returns, and newlines in messages are replaced with spaces.

Argument, prerequisite, authentication, owner-lookup, and full-enumeration
failures emit diagnostics on stderr and no stdout document. Once enumeration
has completed, explicit-repository metadata failures and per-repository
compare/sync failures appear as `error` records. A successful run with no
repositories emits an empty JSON document or TSV header plus summary row.

## Error Handling

- A transient failure while fetching a GraphQL page retries that page only.
- A malformed successful response is treated as transient when it matches the
  existing JSON/HTML error rules.
- Exhausted page retries abort the complete run before any write.
- Compare and sync failures remain repository-scoped so later repositories are
  still processed.
- `ahead` remains a safe skip without force. `diverged` remains blocked without
  force and is not mislabeled as an API or sync failure.

## Verification

Extend the existing fake-`gh` shell tests to prove:

- retry diagnostics use stderr and do not corrupt stdout;
- pagination retains page one while retrying page two;
- TSV and JSON outputs parse and contain expected fields;
- status mode reports divergence with exit 0;
- dry-run and execute mode produce the blocked summary and exit code 2;
- operational errors override divergence with exit code 1;
- the existing retry test captures stdout and stderr separately;
- existing branch mismatch, force, retry, and named-branch behavior still pass.
