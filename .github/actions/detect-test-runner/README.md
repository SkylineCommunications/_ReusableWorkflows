# detect-test-runner

Detects the test runner mode from `global.json`.

- Returns `mtp` when Microsoft.Testing.Platform is configured.
- Returns `vstest` otherwise.

## Inputs

No inputs.

## Outputs

| Output | Description |
| --- | --- |
| `mode` | `mtp` or `vstest`. |

## Used by

- [unit-tests action](../unit-tests/README.md)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- id: detect
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/detect-test-runner@<full-sha>

- run: echo "Runner mode is ${{ steps.detect.outputs.mode }}"
```

### Use in conditional logic

```yaml
- name: Configure test command
  if: steps.detect.outputs.mode == 'mtp'
  run: echo "Using MTP-specific settings"
```
