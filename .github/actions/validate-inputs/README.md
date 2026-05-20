# validate-inputs

Validates runtime prerequisites before expensive build/test/publish work starts.

Checks are conditional so workflows can skip irrelevant validations (for example, Dependabot runs or non-tag builds).

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `sonarcloud-project-name` | no | `""` | SonarCloud project key/name to validate. |
| `sonarcloud-token` | no | `""` | Sonar token (usually from environment). |
| `dataminer-token` | no | `""` | DataMiner token (usually from environment). |
| `repository` | yes | - | Repository value for validation error links. |
| `run-number` | yes | - | Run number used in diagnostics. |
| `has-dataminer-projects` | no | `true` | Whether DataMiner projects are present. |
| `check-sonar` | no | `true` | Enables Sonar validation checks. |
| `check-dataminer` | no | `false` | Enables DataMiner token checks. |

## Outputs

No explicit outputs.

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/validate-inputs@<full-sha>
  with:
    sonarcloud-project-name: ${{ inputs.sonarcloud-project-name }}
    sonarcloud-token: ${{ env.SONAR_TOKEN }}
    repository: ${{ github.repository }}
    run-number: ${{ github.run_number }}
```

### Conditional checks (master workflow pattern)

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/validate-inputs@<full-sha>
  with:
    sonarcloud-project-name: ${{ inputs.sonarcloud-project-name }}
    sonarcloud-token: ${{ env.SONAR_TOKEN }}
    dataminer-token: ${{ env.DATAMINER_TOKEN }}
    repository: ${{ github.repository }}
    run-number: ${{ github.run_number }}
    has-dataminer-projects: ${{ needs.discover_projects.outputs.has-dataminer-projects }}
    check-sonar: ${{ github.actor != 'dependabot[bot]' }}
    check-dataminer: ${{ github.ref_type == 'tag' && needs.discover_projects.outputs.has-dataminer-projects == 'true' }}
```
