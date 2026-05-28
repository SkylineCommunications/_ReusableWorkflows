# sonarcloud-status

Queries SonarCloud for project/branch status and reports whether an initial analysis run is needed.

It also validates token usability and emits actionable errors.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `project-key` | yes | SonarCloud project key. |
| `branch` | yes | Branch name to inspect. |
| `token` | yes | SonarCloud token used for API auth. |
| `repository` | yes | Repository name for error diagnostics. |

## Outputs

| Output | Description |
| --- | --- |
| `needs-initial-analysis` | `true` when no analysis exists yet, else `false`. |

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Connector Master SDK Workflow.yml](../../workflows/Connector%20Master%20SDK%20Workflow.yml)
- [Automation Master SDK Workflow.yml](../../workflows/Automation%20Master%20SDK%20Workflow.yml)

## Usage

### Basic

```yaml
- id: sonar-status
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/sonarcloud-status@main
  with:
    project-key: ${{ inputs.sonarcloud-project-name }}
    branch: ${{ github.ref_name }}
    token: ${{ env.SONAR_TOKEN }}
    repository: ${{ github.repository }}
```

### Gate an initial analysis step

```yaml
- name: Trigger Initial Analysis
  if: steps.sonar-status.outputs.needs-initial-analysis == 'true'
  run: |
    echo "Run bootstrap Sonar analysis here"
```
