# setup-skyline-nuget-sources

Registers all Skyline NuGet sources required by workflows that need access to both Skyline GitHub organizations and the Skyline Azure DevOps feeds.

The action is idempotent: re-running updates existing sources in place.

## Registered Sources

| Source name | Feed |
| --- | --- |
| `PrivateGitHubNugets` | `https://nuget.pkg.github.com/SkylineCommunications/index.json` |
| `SkylineCommunicationsCoreGitHubNugets` | `https://nuget.pkg.github.com/SkylineCommunicationsCore/index.json` |
| `CloudNuGets` | `https://pkgs.dev.azure.com/skyline-cloud/Cloud_NuGets/_packaging/CloudNuGet/nuget/v3/index.json` |
| `PrivateAzureNuGets` | `https://pkgs.dev.azure.com/skyline-cloud/_packaging/skyline-private-nugets/nuget/v3/index.json` |

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `skylinecommunications-github-token` | no | `""` | Token used to authenticate against the SkylineCommunications GitHub Packages feed. The feed is skipped when empty. |
| `skylinecommunicationscore-github-token` | no | `""` | Token used to authenticate against the SkylineCommunicationsCore GitHub Packages feed. The feed is skipped when empty. |
| `azure-token` | no | `""` | Token used to authenticate against the Skyline Azure DevOps NuGet feeds. Both Azure feeds are skipped when empty. |

## Outputs

No outputs.

## Required Permissions

When using `GITHUB_TOKEN`, the caller job needs package read access:

```yaml
permissions:
  contents: read
  packages: read
```

Each GitHub token must be allowed to read packages from its matching Skyline GitHub organization. The Azure token must be allowed to read packages from the Skyline Azure DevOps feeds.

## Used by

- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/setup-skyline-nuget-sources@main
  with:
    skylinecommunications-github-token: ${{ secrets.SKYLINECOMMUNICATIONS_GITHUB_TOKEN }}
    skylinecommunicationscore-github-token: ${{ secrets.SKYLINECOMMUNICATIONSCORE_GITHUB_TOKEN }}
    azure-token: ${{ env.AZURE_TOKEN }}
```

### GitHub feed only

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/setup-skyline-nuget-sources@main
  with:
    skylinecommunications-github-token: ${{ secrets.SKYLINECOMMUNICATIONS_GITHUB_TOKEN }}
```
