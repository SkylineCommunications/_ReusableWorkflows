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
| `Create Prerelease Workflow.yml`                           | Admin-only `/create-prerelease` command for forked NuGet PRs.                 |

## Internal / maintenance workflows

These workflows are not intended to be called from regular caller repos. They
support development of `_ReusableWorkflows` itself or run automatically from
the legacy wrappers.

| Workflow                                                  | Purpose                                                                       |
| --------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `Test Downstream.yml`                                     | Repo-local: runs the downstream battery for `/test`, `/test-all`, or a manual `main` dispatch without a PR; prepares linked Copilot tasks with `/prepare-downstream-fixes`. See [TESTING.md](TESTING.md). |
| `Downstream Gate.yml`                                     | Repo-local: sets the `downstream-tests` commit status on every PR — *pending* when reusable workflows or composite actions are touched, *success (n/a)* otherwise. |
| `Wrapper Migration Workflow.yml`                          | Opens a PR migrating callers off the deprecated redirecting wrappers. Called automatically by those wrappers; can also be dispatched standalone. |
| `Update managed dependency versions.yml`                  | Checks listed stable AppPackageInstaller and DataMiner SDK releases every Monday and creates or updates one review PR. Manual dispatch defaults to dry-run mode but can opt into PR creation from the default branch. |

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

### Prerelease from a fork PR

Install a thin `issue_comment: created` caller on the repository's default
branch. It must pass the existing release workflow filename to
`Create Prerelease Workflow.yml`, pass a repository secret named
`PRERELEASE_TAG_TOKEN`, and grant `contents: read` and `pull-requests: write`
to the job's `GITHUB_TOKEN`. Create a user-owned PAT with `Contents: write`
access only to the participating repositories. Its owner must be allowed by
every applicable tag-creation ruleset (including organization rulesets); the
PAT must be authorized for the organization. Missing credentials fail closed.
The release workflow must have a `push.tags` trigger matching the requested
tag and be available at the PR head. See the caller workflows in the CICD NuGet repositories for
the complete example and their internal GitHub Packages routing.

```yaml
name: Create prerelease from PR
on:
  issue_comment:
    types: [created]
jobs:
  create-prerelease:
    if: github.event.issue.pull_request && startsWith(github.event.comment.body, '/create-prerelease ')
    permissions:
      contents: read
      pull-requests: write
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/Create Prerelease Workflow.yml@main
    with:
      release-workflow: release.yml
    secrets:
      PRERELEASE_TAG_TOKEN: ${{ secrets.PRERELEASE_TAG_TOKEN }}
```

Configure the existing release caller to select the GitHub Packages source
and a `packages: write` token for `-internal.` tags, keeping the normal
NuGet.org source and key for other tags. This command uses its tag-push path.
It accepts any SemVer prerelease suffix, such as `1.2.3-beta.2`. Check the
caller's tag filter and publishing destination before using another suffix:
non-internal tags may publish to NuGet.org.

An administrator comments `/create-prerelease 1.2.3-internal.4` on an open fork
PR. The command uses the **current** PR head and requires an unused version tag,
then tags that commit in the upstream repository without merging the PR. It
does not inspect PR checks; the admin is responsible for reviewing and
approving the current head before commenting. The command does not accept a
reviewed SHA. It creates the tag with the PAT so the existing tag-push release
workflow starts automatically; it does not dispatch a second run. Internal
NuGet packages go to GitHub Packages
only when the caller's release workflow routes `-internal.` tags there; the
shared Master Workflow does not infer the destination from the version.

The command does not restrict manual tags or manual dispatches. Release jobs
run code and workflow YAML from the approved fork commit using their usual
publishing credentials; other tag-only side effects, including Catalog uploads
where configured, still occur. Failed or stale requests do not move existing
tags. A tag left by a late failure must be inspected and recovered manually;
use a new version for a new request rather than retrying an already-created tag.

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
      # Only needed when the repository contains more than one solution.
      # SDK-style connectors only; accepts a .sln or .slnx file name.
      # solution-filter-name: MyConnector.sln
    secrets: inherit
```

### SDK connector compare exception

For one SDK connector revision, the compare-based quality checks can be skipped
by setting the optional `skip-connector-compare` secret in the
`kv-master-cicd-secrets` Azure Key Vault to the exact `Name:Version` from the
solution's `protocol.xml` (for example, `My Connector:2.0.0.7`). Matching is
case- and whitespace-sensitive and requires OIDC. A missing or nonmatching
secret does not change the quality gate; a Key Vault lookup error fails it.

The validator and compare commands still run; only compare-dependent gate
failures are waived. Validation results are required, and critical issues still
fail the gate, as do major or minor issues for an initial version without a
previous revision. Unit tests and SonarCloud are unaffected. The summary
identifies the skipped compare checks and Major Change Checker. Remove the
secret when the exception is no longer needed; its single value authorizes only
one connector revision at a time.

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

## Playwright Docker ACR Workflow

`Playwright Docker ACR Workflow.yml` builds .NET `LiveServiceTesting` test projects, packages them into Docker images, and pushes them to Azure Container Registry.

**For templates, usage instructions, and deployment guides,** see:  
[`SkylineCommunications/platform-delivery-deployments`](https://github.com/SkylineCommunications/platform-delivery-deployments/tree/main/templates/playwright-docker-acr)

**Quick reference:**
- SkylineCommunications repos: uses OIDC (no secrets needed)
- External repos: pass `LIVESERVICETESTS_ACR_*` secrets explicitly
- See [templates README](https://github.com/SkylineCommunications/platform-delivery-deployments/blob/main/templates/playwright-docker-acr/README.md) for quick start

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
