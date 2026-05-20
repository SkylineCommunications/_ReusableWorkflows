# run-unit-tests

Runs unit tests for all test projects in a solution.

The runner is controlled by the required `test-runner-mode` input and integration tests are skipped.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `solution-path` | yes | - | Path to `.sln` or `.slnx`. |
| `configuration` | no | `Release` | Build configuration to test. |
| `test-runner-mode` | yes | - | `mtp` or `vstest`. |

## Outputs

No explicit outputs.

## Used by

- [unit-tests action](../unit-tests/README.md)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic (vstest)

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/run-unit-tests@<full-sha>
  with:
    solution-path: ${{ needs.discover_projects.outputs.solution-path }}
    configuration: ${{ inputs.configuration }}
    test-runner-mode: vstest
```

### Advanced (mode from detect action)

```yaml
- id: detect
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/detect-test-runner@<full-sha>

- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/run-unit-tests@<full-sha>
  with:
    solution-path: ${{ needs.discover_projects.outputs.solution-path }}
    configuration: ${{ inputs.configuration }}
    test-runner-mode: ${{ steps.detect.outputs.mode }}
```
