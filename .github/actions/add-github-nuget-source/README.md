# add-github-nuget-source

Registers a GitHub Packages NuGet source for a GitHub organization.

The action is idempotent: re-running updates an existing source with the same name in place.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `organization` | yes | - | GitHub organization or owner that hosts the NuGet feed. |
| `token` | yes | - | Token used to authenticate against the GitHub Packages feed. |
| `name` | no | `""` | Optional NuGet source name. Defaults to a name derived from `organization`. |

## Outputs

No outputs.

## Required Permissions

When using `GITHUB_TOKEN`, the caller job needs package read access:

```yaml
permissions:
  contents: read
  packages: read
```

The token must be allowed to read packages from the target GitHub organization.

## Used by

- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/add-github-nuget-source@main
  with:
    organization: SkylineCommunications
    token: ${{ secrets.GITHUB_TOKEN }}
```

### Custom source name

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/add-github-nuget-source@main
  with:
    organization: SkylineCommunications
    token: ${{ secrets.GITHUB_TOKEN }}
    name: PrivateGitHubNugets
```
