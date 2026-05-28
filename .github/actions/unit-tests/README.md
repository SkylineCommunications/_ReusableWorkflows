# unit-tests

Convenience wrapper action that:

1. Detects test runner mode (`detect-test-runner`).
2. Executes tests (`run-unit-tests`).

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `solution-path` | yes | - | Path to `.sln` or `.slnx`. |
| `configuration` | no | `Release` | Build configuration to test. |

## Outputs

| Output | Description |
| --- | --- |
| `test-runner-mode` | Detected mode (`mtp` or `vstest`). |

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)

## Usage

### Basic

```yaml
- id: unit-tests
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/unit-tests@main
  with:
    solution-path: ${{ needs.discover_projects.outputs.solution-path }}
    configuration: ${{ inputs.configuration }}
```

### Consume detected runner mode

```yaml
- run: echo "Tests ran with ${{ steps.unit-tests.outputs.test-runner-mode }}"
```
