# load-secrets

Loads secrets into the job environment in two stages:

1. Optionally fetch secrets from Azure Key Vault.
2. Apply caller-provided overrides from `ENV_VAR=VALUE` pairs.

This action writes values to `$GITHUB_ENV` and masks secret values in logs.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `vault-name` | no | `kv-master-cicd-secrets` | Azure Key Vault to query when OIDC is enabled. |
| `use-oidc` | yes | - | `true` to load from Key Vault, `false` to skip Key Vault fetch. |
| `secret-names` | no | `""` | Newline-separated secret names (`foo-bar` becomes `FOO_BAR`). |
| `overrides` | no | `""` | Newline-separated `ENV_VAR=VALUE` pairs. Empty values are skipped. |

## Outputs

No explicit outputs. Variables are exported through `$GITHUB_ENV`.

## Used by

- [Master Workflow.yml](../../workflows/Master%20Workflow.yml)
- [Connector Master SDK Workflow.yml](../../workflows/Connector%20Master%20SDK%20Workflow.yml)
- [Connector Master Legacy Workflow.yml](../../workflows/Connector%20Master%20Legacy%20Workflow.yml)
- [Automation Master SDK Workflow.yml](../../workflows/Automation%20Master%20SDK%20Workflow.yml)
- [Automation Master Legacy Workflow.yml](../../workflows/Automation%20Master%20Legacy%20Workflow.yml)
- [Update Catalog Details Workflow.yml](../../workflows/Update%20Catalog%20Details%20Workflow.yml)

## Limitations

When using Skyline tenant OIDC + Skyline Key Vault, this action is intended to
run inside reusable workflows from this repository.

- Works: when the caller uses a master reusable workflow in
  `_ReusableWorkflows/.github/workflows/`.
- Does not work for Skyline tenant access: when a caller-defined workflow
  invokes this composite action directly.

Reason: the OIDC `job_workflow_ref` claim is tied to the top-level workflow,
not to nested composite actions. Skyline federated credentials restrict that
claim to `_ReusableWorkflows` workflow entry points.

External callers using their own OIDC + Key Vault setup are subject to their
own federated credential policies.

## Usage

### Basic (overrides only)

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/load-secrets@main
  with:
    use-oidc: 'false'
    overrides: |
      SONAR_TOKEN=${{ secrets.SONAR_TOKEN }}
```

### With OIDC + overrides

```yaml
- name: Azure Login
  if: needs.check_oidc.outputs.use-oidc == 'true'
  uses: azure/login@v3
  with:
    client-id: ${{ needs.check_oidc.outputs.client-id }}
    tenant-id: ${{ needs.check_oidc.outputs.tenant-id }}
    subscription-id: ${{ needs.check_oidc.outputs.subscription-id }}

- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/load-secrets@main
  with:
    use-oidc: ${{ needs.check_oidc.outputs.use-oidc }}
    secret-names: |
      azure-token
      sonar-token
    overrides: |
      AZURE_TOKEN=${{ secrets.AZURE_TOKEN }}
      SONAR_TOKEN=${{ secrets.SONAR_TOKEN }}
```

## Notes

- Pass secrets through `env:` in downstream steps, not through `with:`.
- `overrides` are safe to pass directly from optional caller secrets because empty values are ignored.
