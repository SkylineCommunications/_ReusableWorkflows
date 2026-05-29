# apply-catalog-identifiers

Rewrites `id:` values in one or more `CatalogInformation/manifest.yml` files using a newline-separated mapping list.

Each entry must be:

`<manifest.yml path>=<GUID>`

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `mappings` | no | `""` | Newline-separated mapping entries. Empty means no-op. |

## Outputs

No outputs.

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/apply-catalog-identifiers@main
  with:
    mappings: |
      Connector/CatalogInformation/manifest.yml=12345678-1234-1234-1234-123456789abc
```

### No-op mode

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/apply-catalog-identifiers@main
  with:
    mappings: ''
```

## Notes

- The action validates both manifest existence and GUID format before writing.
