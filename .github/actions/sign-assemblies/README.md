# `sign-assemblies`

Authenticode-signs build output assemblies through Azure Key Vault, signing each
**unique file content only once** and copying the signed result back over its
byte-identical duplicates.

## Why deduplicate

The Sign CLI signs one file at a time, so two byte-identical files cost two Key
Vault signing requests for an identical result. A solution copies the same
third-party assemblies into every project's `bin` folder, which multiplies the
request count by the number of projects.

In `SkylineCommunications/SLC_S_CentralOps` that meant **2140 files submitted for
only 141 unique filenames**. The burst trips the per-vault rate limit and the
whole step fails:

```
Request was not processed because too many requests were received.
Reason: VaultRequestTypeLimitReached   Status: 429 (Too Many Requests)
```

Because Sign CLI retries only three times over five seconds, the failure looks
flaky — a re-run usually succeeds once the throttling window has reset.

Grouping by SHA-256 before signing removes the redundant requests. **The action
never leaves a location unsigned:** after the unique representatives are signed,
each one is copied over every other path that held the same content, so every
file that would have been signed before still holds signed bytes.

This action deliberately does **not** filter out third-party or already-signed
assemblies. The set of files that gets signed is unchanged — only the number of
Key Vault requests goes down.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `root` | no | `.` | Root directory to scan for build outputs. |
| `extensions` | no | `dll,exe` | Comma-separated file extensions to sign, without a leading dot. |
| `path-segment` | no | `bin` | Directory segment a file must live under to count as a build output. |
| `publisher-name` | no | `Skyline Communications` | Publisher name embedded in the signature. |
| `description` | no | `Skyline Signing` | Description embedded in the signature. |
| `description-url` | no | `https://www.skyline.be/` | Description URL embedded in the signature. |
| `dry-run` | no | `false` | When `true`, report what would be signed without calling the Sign CLI. |

## Outputs

| Output | Description |
| --- | --- |
| `files-total` | Number of build output files that matched the scan. |
| `files-signed` | Number of unique file contents submitted to Azure Key Vault. |
| `files-copied` | Number of duplicates that received a copy of an already signed file. |
| `batches` | Number of Sign CLI invocations used. |

`files-signed` + `files-copied` always equals `files-total`.

## Required environment

Secrets are passed through `env:`, never `with:`.

| Variable | Purpose |
| --- | --- |
| `AZURE_TENANT_ID` | Tenant of the signing service principal. |
| `AZURE_CLIENT_ID` | Client id of the signing service principal. |
| `AZURE_CLIENT_SECRET` | Client secret of the signing service principal. |
| `SIGNING_KEY_VAULT_URL` | URL of the Key Vault holding the certificate. |
| `SIGNING_KEY_VAULT_CERTIFICATE` | Name of the certificate in the Key Vault. |

The `SIGNING_*` variables are exported to the job environment by the
[`load-secrets`](../load-secrets/README.md) action. `dry-run: true` needs none of
them.

## Requirements

- Runs on a Windows runner (Authenticode signing).
- The `sign` tool must be on `PATH`: `dotnet tool install sign --global --prerelease`.

## Caller permissions

```yaml
permissions:
  contents: read
  id-token: write # only for the azure/login step that precedes this action
```

## Usage

From [`Master Workflow.yml`](../../workflows/Master%20Workflow.yml):

```yaml
- name: Sign assemblies
  id: sign-assemblies
  if: >-
    needs.check_oidc.outputs.use-oidc == 'true' &&
    steps.partition.outputs.remaining-count != '0' &&
    (steps.partition.outputs.wix-count != '0' || steps.partition.outputs.dataminer-package-count != '0')
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/sign-assemblies@main
  env:
    AZURE_TENANT_ID: ${{ env.SIGNING_TENANT_ID }}
    AZURE_CLIENT_ID: ${{ env.SIGNING_CLIENT_ID }}
    AZURE_CLIENT_SECRET: ${{ env.SIGNING_CLIENT_SECRET }}
```

## Tests

`test.ps1` runs the whole corpus offline by shadowing the `sign` tool with a stub
on `PATH`. It asserts the deduplicated counts, that a dry run touches nothing,
that files outside a `bin` folder and non-matching extensions are left alone,
and — most importantly — that **every** path that held a duplicated content ends
up with signed bytes.

```powershell
pwsh -NoProfile -File .github/actions/sign-assemblies/test.ps1
```
