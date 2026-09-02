# update-global-json-sdks

Updates centrally managed `msbuild-sdks` versions in every `global.json` from
the repository root through three subdirectory levels.

Behavior:

- Skips silently when no `global.json` files are found.
- Skips individual files when `msbuild-sdks` is missing.
- Updates managed DataMiner SDK family entries to the shared version.
- Leaves unmanaged entries unchanged.
- Treats the repository root as depth 0 and includes files through depth 3.

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

- The shared DataMiner SDK version constant is defined inside [update-global-json-sdks.ps1](update-global-json-sdks.ps1).
- [Update managed dependency versions.yml](../../workflows/Update%20managed%20dependency%20versions.yml) checks for listed stable releases weekly and maintains the normal version-update PR. Manual dispatch defaults to preview mode; set `dry-run` to `false` from the default branch to create or update the PR.
- For manual changes, keep [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml) expected version checks in sync with the constant.
