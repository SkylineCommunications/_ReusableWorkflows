# add-azure-nuget-source

Registers an Azure DevOps NuGet source by URL.

The action is idempotent: re-running updates an existing source with the same name in place.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `url` | yes | - | Azure DevOps NuGet feed URL. |
| `token` | yes | - | Token used to authenticate against the Azure DevOps NuGet feed. |
| `name` | no | `""` | Optional NuGet source name. Defaults to a name derived from `url`. |

## Outputs

No outputs.

## Required Permissions

No additional `GITHUB_TOKEN` permissions are required beyond reading the repository contents:

```yaml
permissions:
  contents: read
```

The token must be allowed to read packages from the target Azure DevOps feed.

## Used by

- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/add-azure-nuget-source@main
  with:
    url: https://pkgs.dev.azure.com/organization/project/_packaging/feed/nuget/v3/index.json
    token: ${{ secrets.AZURE_TOKEN }}
```

### Custom source name

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/add-azure-nuget-source@main
  with:
    url: https://pkgs.dev.azure.com/skyline-cloud/Cloud_NuGets/_packaging/CloudNuGet/nuget/v3/index.json
    token: ${{ secrets.AZURE_TOKEN }}
    name: CloudNuGets
```
