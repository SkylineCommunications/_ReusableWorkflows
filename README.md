# \_ReusableWorkflows

Centralized GitHub Actions **reusable workflows** used by 2000+ Skyline
repositories. Caller repos reference one of the *master* workflows here so
that build, validation, packaging and publishing logic stays consistent
across the fleet and can be evolved in a single place.

## Master workflows

| Workflow                                                  | Purpose                                                                       |
| --------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `Master Workflow.yml`                                     | Core CI/CD engine — build, validate, package, publish.                        |
| `Connector Master Workflow.yml`                           | CI/CD for DataMiner connector solutions (SDK and Legacy).                     |
| `Connector Master SDK Workflow.yml`                       | SDK-style connector pipeline (validator, Sonar, packaging).                   |
| `Connector Master Legacy Workflow.yml`                    | Legacy connector pipeline.                                                    |
| `Automation Master Workflow.yml`                          | CI/CD for Automation scripts (SDK and Legacy).                                |
| `Automation Master SDK Workflow.yml` / `Legacy`           | SDK / Legacy automation pipelines.                                            |
| `Playwright Docker ACR Workflow.yml`                      | Build and push Playwright .NET test projects to Azure Container Registry.     |
| `NuGet Solution Master Workflow.yml`                      | *(deprecated)* Thin redirect to `Master Workflow.yml` for public NuGet.       |
| `Internal NuGet Solution Master Workflow.yml`             | *(deprecated)* Thin redirect to `Master Workflow.yml` for internal NuGet.     |
| `DataMiner App Packages Master Workflow.yml`              | *(deprecated)* Thin redirect to `Master Workflow.yml` for app packages.       |
| `Update Catalog Details Workflow.yml`                     | Update Catalog metadata on release.                                           |

## Internal / maintenance workflows

These workflows are not intended to be called from regular caller repos. They
support development of `_ReusableWorkflows` itself or run automatically from
the legacy wrappers.

| Workflow                                                  | Purpose                                                                       |
| --------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `Test Downstream.yml`                                     | Repo-local: verifies downstream repos still build against changes here. Triggered by a `/test` PR comment. |
| `Wrapper Migration Workflow.yml`                          | Opens a PR migrating callers off the deprecated redirecting wrappers. Called automatically by those wrappers; can also be dispatched standalone. |

## Using master workflows

The entry point for most caller repositories is `Master Workflow.yml`.
The connector and automation master workflows are dispatchers: they detect
SDK vs. Legacy projects and then call the corresponding sub-pipeline.

### Example: generic solution pipeline (`Master Workflow.yml`)

```yaml
name: CI

on:
  pull_request:
  push:

jobs:
  ci:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Master Workflow.yml@main
    with:
      solution-path: src/MySolution.sln
      sonarcloud-project-name: my-org_my-repo
    secrets: inherit
```

### Example: with OIDC override and catalog identifier mappings

```yaml
jobs:
  ci:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Master Workflow.yml@main
    with:
      solution-path: src/MySolution.sln
      sonarcloud-project-name: my-org_my-repo
      oidc-client-id: ${{ vars.OIDC_CLIENT_ID }}
      oidc-tenant-id: ${{ vars.OIDC_TENANT_ID }}
      oidc-subscription-id: ${{ vars.OIDC_SUBSCRIPTION_ID }}
      override-catalog-identifiers: |
        Connector/CatalogInformation/manifest.yml=12345678-1234-1234-1234-123456789abc
    secrets: inherit
```

### Example: connector dispatcher (`Connector Master Workflow.yml`)

```yaml
jobs:
  ci:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Connector Master Workflow.yml@main
    with:
      connector-name: My Connector
      sonarcloud-project-name: my-org_my-connector
    secrets: inherit
```

### Example: automation dispatcher (`Automation Master Workflow.yml`)

```yaml
jobs:
  ci:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Automation Master Workflow.yml@main
    with:
      sonarcloud-project-name: my-org_my-automation
    secrets: inherit
```

### OIDC boundary (Skyline tenant)

For Skyline-managed Azure OIDC and Key Vault access, the workflow entry point
must be a reusable workflow in this repository (`.github/workflows/*`).

- Supported: caller repo uses `SkylineCommunications/_ReusableWorkflows/.github/workflows/<workflow>.yml@<ref>`.
- Not supported: caller repo directly uses `SkylineCommunications/_ReusableWorkflows/.github/actions/<action>@<ref>` and expects Skyline tenant OIDC to succeed.

This boundary is enforced by Skyline's federated credential subject restriction
on `job_workflow_ref` and applies specifically to Skyline's tenant setup.
External callers using their own OIDC/federated credentials follow their own
subject restrictions.

For implementation details and action-level usage, see
[.github/actions/README.md](.github/actions/README.md).

## Playwright Docker ACR Workflow — build/push, then deploy

`Playwright Docker ACR Workflow.yml` builds a .NET `LiveServiceTesting` test
project, packages it into a Docker image, and pushes that image to the
team's Azure Container Registry. It does **not** deploy or schedule the
image — that's a separate, follow-up step (see below).

### What it does

1. Checks out the caller repo and validates that `image-name` is lowercase
   (required by ACR).
2. Sets up the requested .NET SDK and adds the Skyline NuGet feed.
3. Publishes the `LiveServiceTesting` project at `project-path`.
4. Logs in to the team's ACR and builds/pushes the Docker image using
   `dockerfile-path`, tagged with `image-tag` (and optionally the commit SHA
   when `include-sha-tag: true`).

### Calling it from a team repo

Example based on `SLC-RT-DaaS/.github/workflows/docker-image.yml`:

```yaml
name: Build and Push Playwright Tests

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  build-and-push:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Playwright Docker ACR Workflow.yml@main
    with:
      project-path: 'MyTeam.LiveServiceTesting'   # LiveServiceTesting project folder
      image-name: 'myteam-tests'                  # ACR image name, lowercase only
      dockerfile-path: 'Dockerfile'
      dotnet-version: '8.x'
      image-tag: 'latest'
      include-sha-tag: false
    secrets:
      LIVESERVICETESTS_ACR_LOGIN_SERVER: ${{ secrets.LIVESERVICETESTS_ACR_LOGIN_SERVER }}
      LIVESERVICETESTS_ACR_USERNAME: ${{ secrets.LIVESERVICETESTS_ACR_USERNAME }}
      LIVESERVICETESTS_ACR_PASSWORD: ${{ secrets.LIVESERVICETESTS_ACR_PASSWORD }}
```

`LIVESERVICETESTS_ACR_LOGIN_SERVER` / `_USERNAME` / `_PASSWORD` are the
team's ACR credentials, stored as repo secrets and passed through unchanged.

### Next step: deploying your image

Building and pushing the image is only half the story — it does not run
anywhere on its own. To actually run the image on a schedule in Azure, go to
[`SkylineCommunications/platform-delivery-deployments`](https://github.com/SkylineCommunications/platform-delivery-deployments)
and follow its
[`CONTRIBUTING.md`](https://github.com/SkylineCommunications/platform-delivery-deployments/blob/main/CONTRIBUTING.md):

1. Add or update a `.bicepparam` job file under
   `projects/<project>/job-params/`, referencing the image name/tag you just
   pushed to ACR.
2. Open a PR in `platform-delivery-deployments` with that change.
3. The PR pipeline runs a **what-if preview**, and rollout to the live
   environment requires **manual approval** via a per-project GitHub
   Environment before anything actually deploys.

Secrets for the deployment are handled separately from this repo: job files
reference secrets **by name only**, and the actual values are exchanged
out-of-band with Platform Delivery. See the "Getting a new secret added"
section of `platform-delivery-deployments`'
[`CONTRIBUTING.md`](https://github.com/SkylineCommunications/platform-delivery-deployments/blob/main/CONTRIBUTING.md)
for that process.

## Composite actions

The master workflows above are built on a small set of **shared composite actions** living under [`.github/actions/`](.github/actions). They handle cross-cutting concerns (trigger guarding, OIDC resolution, Key Vault secret loading, NuGet feed setup, input validation, test-runner detection, unit-test execution, catalog manifest rewriting, central-SDK version pinning). See [.github/actions/README.md](.github/actions/README.md) for the catalog and authoring conventions.

---

## Wrapper Migration — automatic on legacy redirecting wrappers

`Wrapper Migration Workflow.yml` is a reusable workflow that rewrites a
caller repo's CI wrapper file(s) from one of the **legacy redirecting**
master workflows to call `Master Workflow.yml` directly, and opens a PR
with the change.

The three legacy wrappers are thin redirects that internally just call
`Master Workflow.yml` with renamed inputs / secrets:

- `NuGet Solution Master Workflow.yml`
- `Internal NuGet Solution Master Workflow.yml`
- `DataMiner App Packages Master Workflow.yml`

Each of those wrappers now also calls `Wrapper Migration Workflow.yml`
on non-PR invocations (branch/tag push, `workflow_dispatch`, schedule)
so that any repo still using the wrapper organically discovers a
migration PR the next time CI runs on a push. The rewrite is mechanical
(rename `with:` / `secrets:` keys, swap the `uses:` reference, drop
obsolete passthrough inputs like `referenceName`/`runNumber`/...), so
the workflow performs it directly instead of delegating to the Copilot
coding agent.

### Trigger gating

The `request_wrapper_migration` job in each legacy wrapper only fires
when:

```yaml
if: github.event_name != 'pull_request'
```

This avoids opening duplicate migration PRs on every PR run and keeps
the migration limited to branch/tag pushes and manual dispatches. The
migration workflow is also idempotent as a second line of defense.

### What it does

1. The legacy wrapper workflow runs `master_workflow:` as before.
2. In parallel, `request_wrapper_migration:` calls
   `Wrapper Migration Workflow.yml` with the appropriate
   `wrapper-kind` (`nuget` / `internal-nuget` / `app-packages`).
3. The migration workflow checks for an open PR with the
   `wrapper-migration` label or a `chore/wrapper-migration-<kind>`
   branch. If one exists, it skips.
4. Otherwise it checks out the caller, rewriting any job whose `uses:` points at
   the legacy wrapper. URL-encoded `uses:` values and pinned git refs
   (`@main`, `@1.2.3`, `@<sha>`) are preserved.
5. If the rewrite produced changes, it opens a PR titled
   `chore: migrate wrapper to call Master Workflow.yml directly` on
   branch `chore/wrapper-migration-<kind>` with label
   `wrapper-migration`.

For repos in the `SkylineCommunications` organization the rewriter
also **drops `SONAR_TOKEN` and `AZURE_TOKEN`** from the migrated
`secrets:` block, because `Master Workflow.yml` already fetches those
from Azure Key Vault via OIDC for Skyline repos. Other secrets
(`NUGET_API_KEY`, `DATAMINER_TOKEN`,
`OVERRIDE_CATALOG_DOWNLOAD_TOKEN`) are kept.

### Guarantees

- **No direct writes to `main`.** Always opens a PR.
- **Idempotent.** Skips if an open PR with the `wrapper-migration`
  label, or a PR from `chore/wrapper-migration-<kind>`, already exists.
- **Scoped per-job.** Only rewrites jobs whose `uses:` references the
  legacy file for the requested kind, so files mixing multiple
  wrappers stay correct.
- **Round-trip YAML.** Uses `ruamel.yaml` so comments and (most)
  formatting in the caller's workflow are preserved.

### Required setup — migration token

The default `GITHUB_TOKEN` **cannot** push commits that modify files
under `.github/workflows/`; GitHub rejects the push unless the token
carries the `workflows` scope. The migration workflow therefore needs a
user-owned token.

The token is retrieved from **Azure Key Vault via OIDC**. The workflow
logs in to Azure and reads `reusable-workflows-token` from
`kv-master-cicd-secrets`. The secret must be a user-owned PAT (or
fine-grained token) with `contents: write`, `pull-requests: write`,
`issues: write`, and **`workflows`** scope on target repos.

For repos in the `SkylineCommunications` organization the OIDC
parameters are auto-defaulted, so no extra setup is required from
caller repos beyond `secrets: inherit`. External callers must
configure their own OIDC + Key Vault setup to provide the token.

If no token is available, the rewrite is computed and the diff is
printed in the job log but no PR is opened (a warning is emitted).
Maintainers can apply the change manually.

### Standalone use (optional)

The workflow can also be called directly (e.g. one-shot sweep across
the fleet on a schedule):

```yaml
jobs:
  Migration:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Wrapper Migration Workflow.yml@main
    with:
      wrapper-kind: nuget   # or internal-nuget, or app-packages
      dry_run: true         # recommended for the initial pilot
```

### Inputs

| Input | Type | Default | Description |
| --- | --- | --- | --- |
| `wrapper-kind` | string | — | One of `nuget`, `internal-nuget`, `app-packages`. Drives the rename map. |
| `dry_run` | boolean | `false` | Log the planned diff without opening a PR. |
| `debug` | boolean | `false` | Verbose logging in the rewrite script. |
| `use-oidc` | string | `false` | When `'true'`, log in to Azure and pull the migration token from Key Vault. |
| `oidc-client-id` / `oidc-tenant-id` / `oidc-subscription-id` | string | — | Azure OIDC parameters (auto-defaulted for `SkylineCommunications`). |
