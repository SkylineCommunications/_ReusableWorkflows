# is-skyline-managed-org

Checks whether a repository owner belongs to the Skyline-managed organization allowlist.

The allowlist is stored in [managed-orgs.txt](managed-orgs.txt). Add future Skyline-managed organizations there once, instead of duplicating owner checks across workflows and composite actions.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `repository-owner` | yes | - | Repository owner (`github.repository_owner`) to check. |

## Outputs

| Output | Description |
| --- | --- |
| `is-skyline-managed` | `true` when the owner is in the allowlist; otherwise `false`. |

## Usage

```yaml
- id: skyline-managed-org
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/is-skyline-managed-org@main
  with:
    repository-owner: ${{ github.repository_owner }}
```