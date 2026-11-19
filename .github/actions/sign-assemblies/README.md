# `sign-assemblies`

Preserves valid, Windows-trusted embedded Authenticode signatures on loose
build outputs. Signs each **remaining unique file content only once** through
Azure Key Vault and copies the signed result over its byte-identical duplicates.

## Signature preflight and signer policy

The existing extension and directory-segment filters select candidates
(`dll,exe` under `bin` by default). After grouping their complete contents by
SHA-256, the action calls Windows `Get-AuthenticodeSignature` once per group:

- **Skip and preserve every path in the group** only when `Status` is `Valid`,
  `SignatureType` is `Authenticode`, and a signer certificate is present.
- **Any Windows-trusted signer is accepted**, including third-party publishers.
  This is not a Skyline-only signature assertion and does not check a publisher
  allowlist or require the configured signing certificate.
- `NotSigned` stays on the normal signing path.
- A `Valid` `Catalog` signature with a signer certificate also stays on the
  signing path, with an explanation in the log: catalog trust is not a portable
  embedded Authenticode signature.
- All other statuses, inconsistent `Valid` metadata, missing verification
  results, and verifier errors **fail explicitly with file/status context**.
  A missing verifier fails clearly when there are candidates to inspect.

Preflight must succeed for the entire scan before any signing or copy-back.
The action does not install certificates or change the Windows trust policy.
There is no new policy input; preservation is the default behavior.

## Why preflight and deduplicate

Sign CLI re-signs files submitted to it, including already-signed files. Skipping
trusted embedded signatures avoids those redundant inputs and Key Vault calls.
Grouping the remaining unsigned contents avoids repeated signing of identical
dependencies copied into multiple build-output folders.

For example, three identical unsigned library copies, one different unsigned
library, and two trusted signed copies produce six matched paths: two signing
representatives, two copies, and two skips. Every unsigned duplicate receives
its representative's signed bytes; trusted paths retain their original bytes.

This reduces redundant requests. It does not claim to eliminate every cause of
HTTP 429 throttling or add a new retry/rate-limiting policy.

## Scope

This changes loose build-output signing only. It does **not** recurse into MSI,
NuGet, DataMiner, ZIP, or other packages, or change their separate signing paths.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `root` | no | `.` | Root directory to scan for build outputs. |
| `extensions` | no | `dll,exe` | Comma-separated file extensions to sign, without a leading dot. |
| `path-segment` | no | `bin` | Directory segment a file must live under to count as a build output. |
| `publisher-name` | no | `Skyline Communications` | Publisher name embedded in the signature. |
| `description` | no | `Skyline Signing` | Description embedded in the signature. |
| `description-url` | no | `https://www.skyline.be/` | Description URL embedded in the signature. |
| `dry-run` | no | `false` | Perform real signature preflight and report planned counts without modifying files or calling Sign CLI. |

## Outputs

| Output | Description |
| --- | --- |
| `files-total` | Number of build output files that matched the scan. |
| `files-signed` | Number of remaining unique contents submitted for signing, or planned in dry-run. |
| `files-copied` | Number of remaining duplicate paths copied from signed representatives, or planned in dry-run. |
| `files-skipped` | Number of matched paths preserved because their embedded Authenticode signature is valid and Windows-trusted. |
| `batches` | Number of Sign CLI invocations used, or planned in dry-run. |

For every successful run:

`files-total = files-signed + files-copied + files-skipped`

`files-skipped` includes **all paths** in preserved groups, not just unique
representatives. An all-skipped scan retains its original nonzero `files-total`
and reports zero signed/copied files and zero batches. An empty scan reports
all zeros.

Dry-run performs the same trust checks and can fail preflight. Its signing,
copying, and batch counts describe planned work, not mutations.

## Required environment

For remaining work in a non-dry-run, signing credentials and settings are passed
through `env:`, never `with:`.

| Variable | Purpose |
| --- | --- |
| `AZURE_TENANT_ID` | Tenant of the signing service principal. |
| `AZURE_CLIENT_ID` | Client id of the signing service principal. |
| `AZURE_CLIENT_SECRET` | Client secret of the signing service principal. |
| `SIGNING_KEY_VAULT_URL` | URL of the Key Vault holding the certificate. |
| `SIGNING_KEY_VAULT_CERTIFICATE` | Name of the certificate in the Key Vault. |

The reusable workflow normally populates these values using
[`load-secrets`](../load-secrets/README.md). This action does not load secrets
or perform an Azure login itself. Dry-run, empty scans, and all-skipped scans
need none of these values.

## Requirements

- A Windows runner with `Get-AuthenticodeSignature` whenever candidates need
  inspection, including in dry-run.
- The `sign` tool on `PATH` only when a non-dry-run has remaining work:
  `dotnet tool install sign --global --prerelease`.
- No Sign CLI or Key Vault settings are required for an all-skipped or empty
  scan, even with `dry-run: false`.

## Caller permissions

```yaml
permissions:
  contents: read
  id-token: write # only for the azure/login step that precedes this action
```

## Usage

[`Master Workflow.yml`](../../workflows/Master%20Workflow.yml) owns the production
invocation, ordering, and authentication. Caller repositories should call that
reusable workflow rather than directly loading Skyline tenant secrets from a
caller workflow. See the production call site for its current conditions and
the [composite smoke job](../../workflows/Test%20composite%20actions.yml) for
secret-free action-interface examples.

The production call passes the signing service-principal values through the
action's environment:

```yaml
env:
  AZURE_TENANT_ID: ${{ env.SIGNING_TENANT_ID }}
  AZURE_CLIENT_ID: ${{ env.SIGNING_CLIENT_ID }}
  AZURE_CLIENT_SECRET: ${{ env.SIGNING_CLIENT_SECRET }}
```

For read-only local inspection on Windows, run from this repository's root
against an existing build-output tree:

```powershell
$env:SIGN_ROOT = 'C:\build\outputs'
$env:SIGN_DRY_RUN = 'true'
& .\.github\actions\sign-assemblies\sign-assemblies.ps1
```

## Tests

`test.ps1` mocks the verifier inside the test helper and shadows `sign` with a
stub on `PATH`. Its synthetic fixtures cover unsigned deduplication/copy-back,
trusted third-party preservation, re-runs, mixed and all-skipped scans, catalog
signatures, fail-closed statuses/metadata/errors, missing verification, and
dry-run byte preservation. There is no production trust bypass.

```powershell
pwsh -NoLogo -NoProfile -File .\.github\actions\sign-assemblies\test.ps1
```

The Windows composite smoke job separately uses real unsigned PE fixtures and
an existing Microsoft-signed binary, asserting that the source has a `Valid`
embedded `Authenticode` signature with a signer certificate. It checks dry-run
counts/unchanged bytes and all-skipped non-dry-run execution without signing
credentials. Neither test path performs live Azure signing, loads a shared
vault, installs certificates, or attempts to reproduce live throttling.
