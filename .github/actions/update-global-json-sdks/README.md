# update-global-json-sdks

Updates centrally managed `msbuild-sdks` versions in `global.json`.

Behavior:

- Skips silently when `global.json` is missing.
- Skips silently when `msbuild-sdks` is missing.
- Updates managed DataMiner SDK family entries to the shared version.
- Leaves unmanaged entries unchanged.

## Inputs

No inputs.

## Outputs

No outputs.

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/update-global-json-sdks@main
```

### Typical placement in CI

```yaml
- name: Update managed SDK versions
  if: needs.discover_projects.outputs.has-dataminer-projects == 'true'
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/update-global-json-sdks@main

- name: Build
  run: dotnet build "${{ needs.discover_projects.outputs.solution-path }}"
```

## Notes

- The shared DataMiner SDK version constant is defined inside [action.yml](action.yml).
- Keep [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml) expected version checks in sync when this version changes.
