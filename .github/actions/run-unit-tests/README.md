# run-unit-tests

Runs unit tests for all test projects in a solution.

The runner is controlled by the required `test-runner-mode` input and integration tests are skipped.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `solution-path` | yes | - | Path to `.sln` or `.slnx`. |
| `configuration` | no | `Release` | Build configuration to test. |
| `test-runner-mode` | yes | - | `mtp` or `vstest`. |
| `coverage` | no | `off` | Use `report` to merge the current run's reports into one Cobertura XML file, or `upload` to also publish it to GitHub. `off` keeps the existing test output layout and does not publish. |

## Outputs

| Output | Description |
| --- | --- |
| `coverage-report` | Path to the merged Cobertura report. Empty when `coverage` is `off` or no coverage was collected. |

## Coverage publishing

Enable [GitHub Code Quality](https://docs.github.com/en/code-security/how-tos/maintain-quality-code/enable-code-quality), set `coverage: upload`, and grant the calling job `code-quality: write` in addition to `contents: read`. For non-default-branch pushes, also grant `pull-requests: read` so the action can look up the PR. GitHub skips uploads from fork PRs. The upload uses `code-coverage/unit-tests-${{ runner.os }}` as its label (`Linux` on Ubuntu, `Windows` on Windows).

Both `report` and `upload` store the raw test results in a run-specific subdirectory under each project's `TestResults` and merge coverage with ReportGenerator (.NET 8 or later). Existing OpenCover and Visual Studio XML formats are retained. The merged report is stored in the runner's temporary directory. If no coverage was collected, nothing is uploaded.

## Used by

- [unit-tests action](../unit-tests/README.md)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic (vstest)

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/run-unit-tests@main
  with:
    solution-path: ${{ needs.discover_projects.outputs.solution-path }}
    configuration: ${{ inputs.configuration }}
    test-runner-mode: vstest
```

### Advanced (mode from detect action)

```yaml
- id: detect
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/detect-test-runner@main

- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/run-unit-tests@main
  with:
    solution-path: ${{ needs.discover_projects.outputs.solution-path }}
    configuration: ${{ inputs.configuration }}
    test-runner-mode: ${{ steps.detect.outputs.mode }}
```
