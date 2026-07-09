# set-repo-type

Writes the **enterprise custom repository property `Workflow-Repo-Type`** on the repository the
workflow runs in, so the governance signal that drives the conditional rulesets stays in sync with
what the repo actually builds — instead of being set by hand at repo creation.

`Workflow-Repo-Type` is a **multi-select** property, so its value is an **array** and a repo can be
more than one type at once (e.g. `["DxM","NuGet"]`).

## Inputs

| Input | Required | Default | Description |
| --- | :--: | --- | --- |
| `repo-types` | yes | — | The value(s) to set — a JSON array (`["DxM","NuGet"]`) or comma-separated list (`DxM,NuGet`) of `DxM` / `NuGet` / `Connector` / `AppPackage`. An empty value leaves the property unchanged. |
| `token` | yes | — | An **organization-owner** token with the **`repo`** scope (the OIDC-gated Key Vault classic PAT `reusable-workflow-token`). The default `GITHUB_TOKEN` **cannot** write custom-property values. |
| `property-name` | no | `Workflow-Repo-Type` | The custom property to write. |

## Behaviour

- **Read-before-write (idempotent):** the action first `GET`s the current property value, compares it
  to the computed set (order-insensitive), and only `PATCH`es when they differ — no churn in the
  audit log on a no-op run.
- **Empty set leaves the value:** when `repo-types` is empty (no type detected), the current value is
  left untouched rather than cleared.
- **Normalisation:** input is matched case-insensitively, de-duplicated, and written in the canonical
  order `DxM, NuGet, Connector, AppPackage`. An unknown value fails the action with a clear error.

## Permission

Writing custom-property **values** is privileged — the default `GITHUB_TOKEN` returns `404`. The
token's user must be an **organization owner** of the repo's org, and the token needs the classic
**`repo`** scope (`admin:org` is not required). A token that is not an org owner of that org gets a
`404` on the write (GitHub hides the resource rather than returning `403`), even though it can still
`GET` the values.

Reads use the per-repo `GET /repos/{owner}/{repo}/properties/values`. Writes try the per-repo
`PATCH /repos/{owner}/{repo}/properties/values` first and, on any error, fall back to the org-level
`PATCH /orgs/{org}/properties/values` (targeting the single repo by name) as a safety net.

## Usage

```yaml
# Connector Master Workflow — always a connector repo:
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/set-repo-type@main
  with:
    repo-types: Connector
    token: ${{ steps.load-secrets.outputs.reusable-workflow-token }}

# Master Workflow — derived from discover_projects (may be several):
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/set-repo-type@main
  with:
    repo-types: ${{ steps.map-repo-types.outputs.repo-types }}   # e.g. "DxM,NuGet"
    token: ${{ steps.load-secrets.outputs.reusable-workflow-token }}
```

Run the write only on the **default branch** so feature branches never flip a repo's governance type:

```yaml
if: github.ref_name == github.event.repository.default_branch
```

## Testing

`test.ps1` dot-sources `set-repo-type.ps1` and unit-tests the pure helpers
(`ConvertTo-RepoTypeSet`, `Test-RepoTypeSetEqual`, `ConvertTo-PropertyPatchBody`) without any API
calls:

```pwsh
pwsh -NoProfile -File ./test.ps1
```
