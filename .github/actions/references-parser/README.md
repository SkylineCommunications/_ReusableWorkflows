# references-parser

Parses the `References:` line in a pull request description (or squash-merge commit message) and validates the mandatory DxM release administration.

The action finds the `References:` line (e.g. `References: [RN44205] [DCP284603] [RN4345] [DCP28543]`), extracts the bracketed ids, normalizes them to upper-case, validates the id format, resolves the `Change-Type` label, and writes a markdown summary for the `skyline-references` sticky PR comment.

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
| `tasks` | JSON array of all normalized DCP task ids. |
| `change-type` | `Patch`, `Minor`, or `Major`. No `Change-Type:*` label resolves to `Patch`. |
| `comment-file` | Absolute path to the rendered markdown summary. |

## Rules

- Ids are declared on a single `References:` line, each wrapped in square brackets, for example
  `References: [RN12] [DCP35]`.
- RN ids must match `RN` followed by digits, for example `RN12`.
- Task ids must match `DCP` followed by digits, for example `DCP35`.
- Ids may appear in any order; duplicates are de-duplicated.
- Regular PRs require at least one RN and at least one task.
- `dependabot[bot]` PRs require an RN only; a human on a `dependabot/*` branch is not exempt.
- At most one `Change-Type:*` label is allowed. Valid values are `Patch`, `Minor`, and `Major`.

## Usage

```yaml
- name: Parse References line
  id: references
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/references-parser@main
  with:
    pr-body: ${{ github.event.pull_request.body }}
    actor: ${{ github.event.pull_request.user.login }}
    labels-json: ${{ toJson(github.event.pull_request.labels.*.name) }}
```

The parser does not fail the step for validation errors. It emits `status=failed` so the caller can still post the sticky comment before enforcing the gate.

## Sticky comment example

The action renders `comment-file`, which the reusable workflow posts as the `skyline-references` sticky
comment. RN and task ids link to their DataMiner collaboration pages.

A passing PR:

```markdown
## PR References Validation: ✅ **Passed**

| Item | Value |
| --- | :---: |
| Status | ✅ |
| Change-Type | Minor |

**Release Notes**

- [RN12](https://collaboration.dataminer.services/releasenotes/12)
- [RN13](https://collaboration.dataminer.services/releasenotes/13)

**Tasks**

- [DCP35](https://collaboration.dataminer.services/task/35)
- [DCP66](https://collaboration.dataminer.services/task/66)
```

A Dependabot PR adds a `Dependabot RN-only mode` row, and the **Tasks** section is omitted unless a
task is linked:

```markdown
## PR References Validation: ✅ **Passed**

| Item | Value |
| --- | :---: |
| Status | ✅ |
| Change-Type | Patch |
| Dependabot RN-only mode | Yes |

**Release Notes**

- [RN99](https://collaboration.dataminer.services/releasenotes/99)
```

A failing PR shows a ❌ status and lists the validation errors:

```markdown
## PR References Validation: ❌ **Failed**

| Item | Value |
| --- | :---: |
| Status | ❌ |
| Change-Type | Patch |

Validation errors:
- Row 1: task id is required for non-Dependabot PRs.
- At least one task id is required for non-Dependabot PRs.

**Release Notes**

- [RN12](https://collaboration.dataminer.services/releasenotes/12)
```

## Tests

The PR validation corpus runs through:

```powershell
pwsh .github/actions/references-parser/test.ps1
```

The same command is wired into [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml).