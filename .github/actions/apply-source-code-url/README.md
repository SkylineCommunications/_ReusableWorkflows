# apply-source-code-url

Finds `CatalogInformation/manifest.yml` files and fills empty `source_code_url:` fields with:

`https://github.com/<repository>`

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `repository` | yes | Usually `${{ github.repository }}`. |

## Outputs

No outputs.

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/apply-source-code-url@<full-sha>
  with:
    repository: ${{ github.repository }}
```

### Conditional for DataMiner projects

```yaml
- if: needs.discover_projects.outputs.has-dataminer-projects == 'true'
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/apply-source-code-url@<full-sha>
  with:
    repository: ${{ github.repository }}
```
