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
| `SRM Function Master Workflow.yml`                        | CI/CD for SRM functions.                                                      |
| `NuGet Solution Master Workflow.yml`                      | *(deprecated)* Thin redirect to `Master Workflow.yml` for public NuGet.       |
| `Internal NuGet Solution Master Workflow.yml`             | *(deprecated)* Thin redirect to `Master Workflow.yml` for internal NuGet.     |
| `DataMiner App Packages Master Workflow.yml`              | *(deprecated)* Thin redirect to `Master Workflow.yml` for app packages.       |
| `Update Catalog Details Workflow.yml`                     | Update Catalog metadata on release.                                           |
| `Test Downstream.yml`                                     | Verifies downstream repos still build against changes here.                   |
| `SDK Migration Workflow.yml`                              | Detects legacy csproj and asks Copilot to open a migration PR.                |
| `Wrapper Migration Workflow.yml`                          | Opens a PR migrating callers off the deprecated redirecting wrappers.         |

---

## SDK Migration (agentic) — automatic on legacy repos

`SDK Migration Workflow.yml` is an **agentic** reusable workflow that
helps move older connector repos off the legacy csproj format and onto
the SDK-style csproj that the modern `Connector Master SDK Workflow.yml`
pipeline expects.

It is **wired into `Connector Master Workflow.yml`** and triggers
automatically when the legacy path is taken — no per-repo opt-in needed.
This way, developers working on an old repo organically discover a
migration PR the next time CI runs on the default branch.

### What it does

1. The connector master workflow's `check_solution_type` job runs
   `SDKChecker`. If `isSdk=false`, the `CI_Legacy` job runs as before.
2. In parallel, `Request_SDK_Migration` calls this workflow with
   `assume_legacy: true`.
3. The workflow checks for an existing open issue/PR with the
   `sdk-migration` label, or an open PR from `chore/sdk-migration`. If
   one exists, it skips.
4. Otherwise it opens a GitHub Issue with a detailed migration brief and
   **assigns it to the GitHub Copilot coding agent**.
5. Copilot iterates on the conversion, runs `dotnet build` and
   `dataminer-validator` in its own sandbox, and opens a PR titled
   `chore: migrate to SDK-style csproj`.
6. That PR runs through the normal `Connector Master Workflow.yml` —
   which now takes the **SDK** path — so the same quality gate that
   protects human PRs also protects this agent-generated PR.

### Trigger gating

The migration request only fires when **all** of the following are true:

- The solution is legacy-style (`isSdk == 'false'`).
- The event is a `push` (not a `pull_request` or tag).
- The push is to the **default branch** of the repo.

This avoids creating duplicate issues from PR runs or feature-branch
pushes. The reusable workflow is also idempotent as a second line of
defense.

### Guarantees

- **No direct writes to `main`.** The agent always opens a PR.
- **Idempotent.** Skips if an open issue or PR with the `sdk-migration`
  label, or a PR from `chore/sdk-migration`, already exists.
- **Quality-gated.** The agent's PR goes through the same SDK pipeline
  that protects human PRs.
- **Least privilege.** Job-scoped `permissions:` (`contents: read`,
  `issues: write`, `pull-requests: read`).
- **Falls back gracefully.** If the Copilot coding agent assignment
  fails (e.g. no user token, agent not enabled on the repo), the issue
  is still created (unassigned) so the work is tracked.

### Required setup — shared `reusable-workflows-token`

GitHub does **not** allow assigning the Copilot coding agent with the
default `GITHUB_TOKEN`, because it is a GitHub App installation token
and the `replaceActorsForAssignable` mutation is restricted to
user-owned tokens. The workflow therefore needs a separate token to
perform the assignment. Without one, the issue is still created and
labeled — it just remains unassigned (you'll see a warning in the log).

The **same** `reusable-workflows-token` is also consumed by
`Wrapper Migration Workflow.yml` (see below) to push migration PRs.
One token, two consumers — provision it once in Key Vault.

Required scopes (fine-grained PAT):
`contents: write`, `pull-requests: write`, `issues: write`,
`workflows: write`, `metadata: read`. Classic PATs need `repo` +
`workflow`.

The only supported source is **Azure Key Vault via OIDC**. The
master workflow's `check_oidc` job produces the OIDC parameters; the
migration workflow uses them to `azure/login@v3` and pull
`reusable-workflows-token` from `kv-master-cicd-secrets`. Nothing
extra is required from caller repos; just keep using
`secrets: inherit` when calling the master workflow.

External callers (outside the SkylineCommunications organization) who
want the issue assigned to Copilot must either configure their own
OIDC + Key Vault pulling a secret of the same name, or accept that
the issue will be created unassigned and assign it manually.

If no token is available, the issue is still created and labeled
(unassigned) and a warning is emitted.

### Standalone use (optional)

The workflow can also be called directly (e.g. on a schedule across the
fleet) if you want a one-shot sweep instead of waiting for each repo's
next push to its default branch:

```yaml
jobs:
  Migration:
    uses: SkylineCommunications/_ReusableWorkflows/.github/workflows/SDK Migration Workflow.yml@main
    with:
      dry_run: true   # recommended for the initial pilot
```

When called standalone, omit `assume_legacy` and the workflow will run
`SDKChecker` itself.

### Inputs

| Input                  | Type    | Default              | Description                                                                          |
| ---------------------- | ------- | -------------------- | ------------------------------------------------------------------------------------ |
| `assume_legacy`        | boolean | `false`              | Caller asserts the solution is legacy-style; skips the SDKChecker run.               |
| `assignee`             | string  | `copilot-swe-agent`  | Login of the Copilot coding agent (override only if needed).                         |
| `dry_run`              | boolean | `false`              | Log the planned issue without creating it.                                           |
| `debug`                | boolean | `false`              | Verbose logging.                                                                     |
| `use-oidc`             | string  | `false`              | When `'true'`, log in to Azure and pull `reusable-workflows-token` from Key Vault.   |
| `oidc-client-id`       | string  | —                    | Azure OIDC client id (passed through by the master workflow's `check_oidc` job).     |
| `oidc-tenant-id`       | string  | —                    | Azure OIDC tenant id.                                                                |
| `oidc-subscription-id` | string  | —                    | Azure OIDC subscription id.                                                          |

---

## Cost & rate limits

The SDK Migration workflow consumes Copilot coding agent capacity. At
2000+ repos:

- Trigger gating (push to default branch only, idempotency check) keeps
  volume bounded.
- Review Copilot agent throughput before assuming fleet-wide rollout is
  smooth.

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
The same token is used by `SDK Migration Workflow.yml` to assign
the Copilot coding agent to migration issues.

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
