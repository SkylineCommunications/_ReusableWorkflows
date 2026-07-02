# parse-rn-task-table

Parses the RN/Task table in a pull request description and validates the mandatory DxM release administration.

The action finds the markdown table with `RN` and `Task` header columns, parses comma-separated ids per row, normalizes ids to upper-case, validates the id format, resolves the `Change-Type` label, and writes a markdown summary for the `skyline-rn-task` sticky PR comment.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `pr-body` | yes | Pull request description markdown. |
| `actor` | yes | Pull request author login. Only `dependabot[bot]` may omit task ids. |
| `labels-json` | yes | JSON array of PR label names. Used to resolve `Change-Type`. |

## Outputs

| Output | Description |
| --- | --- |
| `status` | `passed` or `failed`. |
| `rns` | JSON array of all normalized RN ids. |
| `pairs` | JSON array of row groupings, each shaped as `{ "rns": [...], "tasks": [...] }`. |
| `change-type` | `Patch`, `Minor`, or `Major`. No `Change-Type:*` label resolves to `Patch`. |
| `comment-file` | Absolute path to the rendered markdown summary. |

## Rules

- RN ids must match `RN` followed by digits, for example `RN12`.
- Task ids must match `DCP` followed by digits, for example `DCP35`.
- Multiple ids in one cell are comma-separated and treated as one linked grouping.
- Regular PRs require at least one RN and at least one task, and every RN row must have a task.
- `dependabot[bot]` PRs require an RN only; a human on a `dependabot/*` branch is not exempt.
- At most one `Change-Type:*` label is allowed. Valid values are `Patch`, `Minor`, and `Major`.

## Usage

```yaml
- name: Parse RN/Task table
  id: rn-task
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/parse-rn-task-table@main
  with:
    pr-body: ${{ github.event.pull_request.body }}
    actor: ${{ github.event.pull_request.user.login }}
    labels-json: ${{ toJson(github.event.pull_request.labels.*.name) }}
```

The parser does not fail the step for validation errors. It emits `status=failed` so the caller can still post the sticky comment before enforcing the gate.

## Tests

The 16-case PR validation corpus runs through:

```powershell
pwsh .github/actions/parse-rn-task-table/test.ps1
```

The same command is wired into [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml).