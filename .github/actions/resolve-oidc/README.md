# resolve-oidc

Resolves Azure OIDC settings used by `azure/login` and downstream secret-loading jobs.

Resolution order:

1. Use explicit caller-provided inputs when present.
2. Else use Skyline defaults when `repository-owner == SkylineCommunications`.
3. Else set `use-oidc=false`.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `client-id` | no | `""` | Caller-provided OIDC client id. |
| `tenant-id` | no | `""` | Caller-provided OIDC tenant id. |
| `subscription-id` | no | `""` | Caller-provided OIDC subscription id. |
| `repository-owner` | yes | - | Repository owner, typically `${{ github.repository_owner }}`. |

## Outputs

| Output | Description |
| --- | --- |
| `client-id` | Resolved client id. |
| `tenant-id` | Resolved tenant id. |
| `subscription-id` | Resolved subscription id. |
| `use-oidc` | `true` when OIDC can be used, else `false`. |

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Connector Master Workflow.yml](../../workflows/Connector%20Master%20Workflow.yml)
- [Automation Master Workflow.yml](../../workflows/Automation%20Master%20Workflow.yml)
- [Update Catalog Details Workflow.yml](../../workflows/Update%20Catalog%20Details%20Workflow.yml)

## Limitations

For Skyline tenant OIDC access, this action must run inside jobs whose
top-level entry workflow is in `_ReusableWorkflows/.github/workflows/`.

- Works: when called from master reusable workflows in this repository.
- Does not work for Skyline tenant access: when a caller-defined workflow
  invokes this composite action directly.

Reason: composite actions do not change the OIDC `job_workflow_ref` claim.
Skyline's federated credential checks that claim against
`SkylineCommunications/_ReusableWorkflows/*`.

External callers using their own OIDC setup are governed by their own
federated credential rules.

## Usage

### Basic

```yaml
- id: resolve
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/resolve-oidc@<full-sha>
  with:
    repository-owner: ${{ github.repository_owner }}
```

### Explicit OIDC override

```yaml
- id: resolve
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/resolve-oidc@<full-sha>
  with:
    client-id: ${{ inputs.oidc-client-id }}
    tenant-id: ${{ inputs.oidc-tenant-id }}
    subscription-id: ${{ inputs.oidc-subscription-id }}
    repository-owner: ${{ github.repository_owner }}

- name: Azure Login
  if: steps.resolve.outputs.use-oidc == 'true'
  uses: azure/login@v3
  with:
    client-id: ${{ steps.resolve.outputs.client-id }}
    tenant-id: ${{ steps.resolve.outputs.tenant-id }}
    subscription-id: ${{ steps.resolve.outputs.subscription-id }}
```
