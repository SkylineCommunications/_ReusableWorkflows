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
| `NuGet Solution Master Workflow.yml`                      | *(deprecated)* Thin redirect to `Master Workflow.yml` for public NuGet.       |
| `Internal NuGet Solution Master Workflow.yml`             | *(deprecated)* Thin redirect to `Master Workflow.yml` for internal NuGet.     |
| `DataMiner App Packages Master Workflow.yml`              | *(deprecated)* Thin redirect to `Master Workflow.yml` for app packages.       |
| `Update Catalog Details Workflow.yml`                     | Update Catalog metadata on release.                                           |
| `Test Downstream.yml`                                     | Verifies downstream repos still build against changes here.                   |
| `Wrapper Migration Workflow.yml`                          | Opens a PR migrating callers off the deprecated redirecting wrappers.         |

## Composite actions

The master workflows above are built on a small set of **shared composite actions** living under [`.github/actions/`](.github/actions). They handle cross-cutting concerns (trigger guarding, OIDC resolution, Key Vault secret loading, NuGet feed setup, input validation, test-runner detection, catalog manifest rewriting, central-SDK version pinning). See [.github/actions/README.md](.github/actions/README.md) for the catalog and authoring conventions.

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

| Input                     | Type    | Default  | Description                                                                       |
| ------------------------- | ------- | -------- | --------------------------------------------------------------------------------- |
| `wrapper-kind`            | string  | —        | One of `nuget`, `internal-nuget`, `app-packages`. Drives the rename map.          |
| `dry_run`                 | boolean | `false`  | Log the planned diff without opening a PR.                                        |
| `debug`                   | boolean | `false`  | Verbose logging in the rewrite script.                                            |
| `use-oidc`                | string  | `false`  | When `'true'`, log in to Azure and pull the migration token from Key Vault.       |
| `oidc-client-id` / `oidc-tenant-id` / `oidc-subscription-id` | string | — | Azure OIDC parameters (auto-defaulted for `SkylineCommunications`). |
