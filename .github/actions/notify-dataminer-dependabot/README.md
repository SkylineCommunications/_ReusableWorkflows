# notify-dataminer-dependabot

Sends one signed Catalog publication notification per distinct published Catalog ID. A failure to deliver produces a workflow warning and job-summary entry without failing an already published release. The signing secret comes from the existing `dataminer-dependabot-catalog-webhook-secret` Key Vault secret.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `catalog-ids` | no | `''` | Newline-separated Catalog GUIDs from published artifacts. |
| `version` | yes | | Published Catalog version. |

## Outputs

No outputs.

## Permissions and setup

The caller needs `id-token: write` for `azure/login` and permission to read the secret from `kv-master-cicd-secrets`. Before invoking the action, load `dataminer-dependabot-catalog-webhook-secret` with `load-secrets@main` in the same job. The action reads `DATAMINER_DEPENDABOT_CATALOG_WEBHOOK_SECRET` from the environment. It sends to the currently deployed public Container App URL; update the action URL if that hostname changes.

## Usage

```yaml
- name: Notify DataMiner Dependabot
  if: success() && needs.check_oidc.outputs.is-skyline-managed == 'true'
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/notify-dataminer-dependabot@main
  with:
    catalog-ids: ${{ steps.catalog-ids.outputs.ids }}
    version: ${{ github.ref_name }}
```

Call this only after successful Catalog publication. The event ID uses the workflow run ID and Catalog ID, so rerun attempts use the same idempotency key.