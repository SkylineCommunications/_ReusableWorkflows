# setup-nuget-sources

Registers NuGet feeds required by the reusable workflows.

Always registers the owner-scoped GitHub Packages feed and can also register Skyline Azure feeds. The action is idempotent: re-running updates existing sources in place.

This action composes [add-github-nuget-source](../add-github-nuget-source/README.md) and [add-azure-nuget-source](../add-azure-nuget-source/README.md) while preserving the legacy source names used by existing workflows.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `repository-owner` | yes | - | Repository owner (`github.repository_owner`). |
| `github-token` | yes | - | Token for GitHub Packages authentication. |
| `azure-token` | no | `""` | PAT for Skyline Azure DevOps feeds. |
| `include-skyline` | no | `auto` | `true`, `false`, or `auto` (enabled only for Skyline owner). |

## Outputs

No explicit outputs.

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Connector Master SDK Workflow.yml](../../workflows/Connector%20Master%20SDK%20Workflow.yml)
- [Automation Master SDK Workflow.yml](../../workflows/Automation%20Master%20SDK%20Workflow.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/setup-nuget-sources@main
  with:
    repository-owner: ${{ github.repository_owner }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

### Force GitHub feed only

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/setup-nuget-sources@main
  with:
    repository-owner: ${{ github.repository_owner }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    include-skyline: 'false'
```

## Notes

- Keep tokens in `env:` for downstream commands; do not pass secrets through `with:` in custom scripts.
- When Skyline feeds are required, supply `azure-token` or rely on `load-secrets` output.
