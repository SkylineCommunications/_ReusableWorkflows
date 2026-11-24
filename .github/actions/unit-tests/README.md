# unit-tests

Convenience wrapper action that:

1. Detects test runner mode (`detect-test-runner`).
2. Executes tests (`run-unit-tests`).

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `solution-path` | yes | - | Path to `.sln` or `.slnx`. |
| `configuration` | no | `Release` | Build configuration to test. |
| `coverage` | no | `off` | Use `report` to produce a merged Cobertura report or `upload` to publish it to GitHub. |

## Outputs

| Output | Description |
| --- | --- |
| `test-runner-mode` | Detected mode (`mtp` or `vstest`). |
| `coverage-report` | Path to the merged Cobertura report, if one was produced. |

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

### Publish coverage to GitHub

Grant the calling job the required permissions (and `pull-requests: read` for non-default-branch pushes):

```yaml
permissions:
  contents: read
  code-quality: write
```

In the job's steps, after building the solution:

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/unit-tests@main
  with:
    solution-path: MySolution.slnx
    coverage: upload
```

On pull requests, check out `${{ github.event.pull_request.head.sha || github.sha }}` so the report matches the commit GitHub annotates. Run on default-branch pushes as well to establish a coverage baseline.

See [coverage publishing](../run-unit-tests/README.md#coverage-publishing) for report locations and OS-specific labels. The shared Master Workflow does not opt in.

### Consume detected runner mode

```yaml
- run: echo "Tests ran with ${{ steps.unit-tests.outputs.test-runner-mode }}"
```
