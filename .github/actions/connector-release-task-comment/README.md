# connector-release-task-comment

Reads the matching released version from a DataMiner connector's namespaced
`protocol.xml`, formats the historical release comment, and updates each unique
`<VersionHistory>/<Branches>/<Branch>/<SystemVersions>/<SystemVersion>/<MajorVersions>/<MajorVersion>/<MinorVersions>/<MinorVersion>/References/TaskId`
through `PATCH /api/tasks/batch`.

The action only accepts stable numeric connector tags (`1.2.3` or
`1.2.3.4`, with an optional leading `v`). Tags with a prerelease suffix,
branches, and missing or ambiguous release metadata fail closed. It never uses
PR references to select tasks. A successful pipeline result is supplied by the
caller so the SLC quality-gates line is added only after the selected SDK or
Legacy pipeline, including artifact registration, succeeds.

## Required caller permissions

The release workflow needs:

```yaml
permissions:
  contents: read
  id-token: write # only when the caller loads Skyline credentials from Key Vault
```

`id-token: write` is not needed when both explicit credentials are supplied.
The action itself does not need GitHub API permissions.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `protocol-file` | no | `protocol.xml` | Checked-out connector protocol XML, relative to the workspace or absolute. |
| `release-tag` | yes | — | Stable numeric connector tag. |
| `quality-gates-passed` | yes | — | `true` when the selected pipeline completed successfully. |
| `api-base-url` | no | `https://api.skyline.be` | Collaboration API base URL. |
| `dry-run` | no | `false` | Render and validate metadata without authentication or API requests. |
| `api-timeout-seconds` | no | `30` | HTTP request timeout. |

## Outputs

| Output | Description |
| --- | --- |
| `status` | `success` or `failed`. |
| `connector-name` | Connector `<Name>` value. |
| `released-version` | Matching four-component version-history version. |
| `task-ids` | Compact JSON array of unique numeric task IDs in source order. |
| `comment-file` | Workspace path containing the rendered comment. |

## Credentials

The action follows the existing Skyline API convention. The caller passes
credentials through environment variables, never action inputs:

- `SKYLINE_USERNAME`
- `SKYLINE_PASSWORD`

`Connector Master Workflow.yml` optionally loads `skyline-username` and
`skyline-password` from the existing OIDC/Key Vault flow and accepts optional
reusable-workflow secrets with the same uppercase names as explicit overrides.
The script masks and never prints either value. Do not pass `api-key` or
`DATAMINER_TOKEN`; those credentials are for Catalog/NuGet operations and are
not accepted here.

## Usage

The dispatcher calls the action after both connector routes are in the `needs`
graph and checks the active route with an `always()`-safe condition:

```yaml
- name: Update Collaboration Tasks
  id: update
  continue-on-error: true
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/connector-release-task-comment@main
  with:
    release-tag: ${{ github.ref_name }}
    quality-gates-passed: ${{ needs.CI_SDK.result == 'success' }}
  env:
    SKYLINE_USERNAME_OVERRIDE: ${{ secrets.SKYLINE_USERNAME }}
    SKYLINE_PASSWORD_OVERRIDE: ${{ secrets.SKYLINE_PASSWORD }}
```

`continue-on-error: true` is intentional: a task API or credential failure is
reported in the step log and Job Summary while the already successful connector
release remains successful. The API uses `POST /Token`, reads each current task
version with `GET /api/tasks/byid?ids[]=<id>`, and sends the current `ID`, `Version`,
and formatted `Comment` values in one `PATCH /api/tasks/batch` request. A 409/412
optimistic-concurrency response causes one safe re-read and retry. Re-running a
release updates the same task Comment fields and does not create separate
comment resources.

## Offline tests

The fixture and fake-server tests do not contact Skyline infrastructure:

```bash
python3 -m unittest discover -s .github/actions/connector-release-task-comment/tests -p 'test_*.py'
```

The in-repository `Test composite actions.yml` smoke test invokes the composite
interface in `dry-run` mode and asserts its outputs and rendered comment.
