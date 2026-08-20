---
description: "Conventions for editing reusable workflows and composite actions inside SkylineCommunications/_ReusableWorkflows."
applyTo: ".github/workflows/**,.github/actions/**"
---

# `_ReusableWorkflows` authoring conventions

This file applies when editing workflows under `.github/workflows/` or composite actions under `.github/actions/` **inside the `_ReusableWorkflows` repo**. For broader org-wide guidance on consuming these workflows from caller repos, the `skyline-workflow-author` Copilot agent (org-level) is the source of truth.

## Source-of-truth references

- Master workflow catalog and deprecation rules: [README.md](../../README.md)
- Composite action conventions: [.github/actions/README.md](../actions/README.md)
- Downstream integration-test battery (coverage, /test usage, adding scenarios): [TESTING.md](../../TESTING.md)

## Editing reusable workflows (`.github/workflows/*.yml`)

- **Do not add another wrapper workflow.** New input scenarios go into [`Master Workflow.yml`](../workflows/Master%20Workflow.yml). The three deprecated wrappers (`NuGet Solution Master Workflow.yml`, `Internal NuGet Solution Master Workflow.yml`, `DataMiner App Packages Master Workflow.yml`) are kept only as redirects; do not extend them.
- **First step is `guard-trigger`** (or its SHA-pinned external form). It rejects `pull_request_target`.
- **OIDC parameters flow top-down.** Resolve once via `resolve-oidc` and pass `oidc-client-id` / `oidc-tenant-id` / `oidc-subscription-id` / `use-oidc` through to any sub-workflow that needs Key Vault access.
- **Secrets travel via `env:`, never `with:`.** Never log secrets.
- **Job-scoped `permissions:`** — start from the least set the job needs (`contents: read` minimum) and add only what is required.

### Catalog workflow compatibility

When editing [`Update Catalog Details Workflow.yml`](../workflows/Update%20Catalog%20Details%20Workflow.yml):

- Keep DataMiner project detection exactly aligned with [`Master Workflow.yml`](../workflows/Master%20Workflow.yml): scan every `*.csproj`, parse it as XML, and treat the repository as a DataMiner SDK scenario when any project contains a `DataMinerType` element. Do not introduce a different SDK-detection heuristic without updating Master Workflow as well.
- In the DataMiner SDK scenario, process each package manifest under a `CatalogInformation` directory. SDK package manifests are guaranteed to use this location.
- In the legacy connector/automation scenario, preserve the existing root `catalog.yml` / `manifest.yml` behavior.
- Catalog generation through `github-to-catalog-yaml` and the commit/push of `.githubtocatalog/auto-generated-catalog.yml` are legacy-only operations. Skip all of them for the DataMiner SDK scenario.
- Before changing permissions, inspect the permissions required by each actual step and action. Do not add scopes such as `actions: write` based only on artifact upload or other assumptions; keep the smallest verified set and use job-level permissions.

### Workflow validation checklist

After editing a reusable workflow:

1. Run the editor diagnostics or an available YAML/workflow validator and fix structural errors before reviewing warnings.
2. Check that every job-level mapping (`name`, `runs-on`, `needs`, `permissions`, `steps`) is aligned consistently.
3. Verify both relevant branches when conditional behavior is changed: legacy connector/automation and DataMiner SDK multi-package repositories.
4. Confirm that skipped steps cannot be referenced as though they produced outputs in the active branch.
5. Review the final diff for unrelated changes and confirm permissions remain least-privilege.

### Script and tool validation

- PowerShell comparison operators applied to arrays return the matching or non-matching elements, not one Boolean result. Join command output before using `-match` or `-notmatch`, or use an explicit predicate such as `Where-Object`.
- Some command-line tools return a failure code when a glob matches no files. Before invoking a tool for an optional artifact type, explicitly check whether matching files exist. Do not suppress failures from an invocation that had actual inputs.
- A composite action's smoke test must exercise the same invocation path used by its workflow caller, including the composite interface, outputs, and command-output parsing. An offline script test alone does not validate the workflow wrapper.

### Partitioned build ordering

- When a later build stage consumes signed outputs from an earlier stage, pass `BuildProjectReferences=false` to the later build. Otherwise MSBuild can rebuild a dependency and replace its signed output.
- Treat artifact staging directories as explicit contracts between build stages. Verify that required artifacts exist before starting the consuming stage.
- Preserve every solution format accepted by the caller when introducing solution manipulation. `solution-filter-name` can resolve to `.sln`, `.slnx`, or `.slnf`; tests for `.slnf` must also verify that its backing solution remains unchanged.

### Documentation sync

For important changes to reusable workflows or their behavior, check whether the corresponding documentation in `C:\GitHub\dataminer-docs\develop\CICD\GitHub\GitHubReusableWorkflows` also needs to be updated. Before finishing, ask the user whether they will make the documentation changes themselves or want guidance through making them. Do not require documentation changes for minor, internal, or non-user-visible workflow updates.

### Downstream battery coupling

The downstream test battery ([TESTING.md](../../TESTING.md)) asserts on **concrete names** inside the reusable workflows. Renaming any of these breaks downstream verify jobs even when the pipeline itself still works — update the affected downstream scenarios in the same change and run `/test`:

- Artifact names: `SignedNugetPackages`, `SignedDataMinerPackages`, `SignedInstallers`, `debian-package`, `Connector Package`, `validatorResults`, `SBOM`, `Catalog Details`.
- Job display names: `Discover Project Types`, `Push NuGet Packages`, `Upload to Catalog`, `Package & Sign (Windows)`, `SDK Skyline Quality Gate`, `Artifact Registration and Upload`, `Validate Trigger`, `Migrate wrapper to Master Workflow` (and its step `Create migration PR (dry run)`).
- Log lines: the `sign-assemblies` summary `N unique file content(s) to sign, M duplicate(s) to copy afterwards` (SharedLibrary's verify asserts M > 0 to guard the Azure 429 deduplication from PR #153).
- Failure semantics relied on by NegativePaths: multi-solution discovery error, apply-catalog-identifiers rejection, validator quality-gate initial-version rule and missing-results fail-closed path, guard-trigger rejection of `pull_request_target`.

When adding a new input or feature to a master workflow, add a scenario for it (see "Adding coverage" in [TESTING.md](../../TESTING.md)) — a feature without a downstream scenario is unprotected against regressions.

## Referencing composite actions from inside this repo

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/<name>@main
```

- Use `@main` for intra-repo composite and reusable-workflow references. This is the de facto convention across the fleet and across every workflow in this repo today.
- Third-party `uses:` (e.g. `actions/checkout@v6`, `azure/login@...`) must still be pinned to a tag or full commit SHA.
- The relative form `uses: ./.github/actions/<name>` is reserved for the `guard-trigger` first-step chicken-and-egg exception. Do not use it elsewhere.

## Adding or editing composite actions (`.github/actions/<name>/`)

Mirrors [.github/actions/README.md](../actions/README.md):

1. **Folder layout**: `action.yml` + `<name>.ps1` and/or `<name>.sh` (or task-named scripts for larger actions). Heavy logic lives in the scripts. The composite `run:` step should be a single line invoking the script. Only trivial one-liners (e.g. `guard-trigger`) may stay inline in `action.yml`.
2. **Naming**: kebab-case folder, kebab-case inputs and outputs. `name:` and `description:` are required on the action and on every input/output.
3. **Always set explicit `shell:`** on `run:` steps (`bash` or `pwsh`).
4. **Pass `${{ inputs.* }}` and `${{ github.* }}` through `env:`** — never interpolate them inside a script body. Reference them as shell variables (`$env:FOO` in pwsh, `$FOO` in bash).
5. **No secrets in `with:`** — pass tokens via `env:` to avoid logging.
6. **Outputs are surfaced through a step `id:`**, for example `value: ${{ steps.detect.outputs.test-runner-mode }}`.
7. **Idempotency** when the action mutates external state (NuGet sources, manifest files). Re-running the same step twice must not break.

### Required follow-ups when adding a new composite action

Adding the `action.yml` is **not** enough. A new composite is only complete once **all** of the following are done in the same PR — reviewers should reject PRs that skip any of these:

1. **Per-action `README.md`** inside `.github/actions/<name>/` describing inputs, outputs, required caller `permissions:`, and at least one realistic usage snippet.
2. **Catalog row** appended to the table in [.github/actions/README.md](../actions/README.md). One row per action, in the same format as the existing entries, linking to the per-action README.
3. **Smoke-test job** added to [`Test composite actions.yml`](../workflows/Test%20composite%20actions.yml) that exercises the action and asserts on its outputs (and idempotency when applicable). Actions that need live secrets (e.g. `sonarcloud-status`) are gated to `workflow_dispatch` — follow that pattern instead of skipping the test.
4. **Caller wiring** from whichever master workflow consumes the action, using the same pin convention as the surrounding references.

If a change touches an existing action's inputs/outputs/behavior, update items 1–3 in lockstep with the code change.

## Migration workflows are part of the design

When touching anything that interacts with the deprecated redirecting wrappers, remember that a migration workflow exists and will run automatically:

- [`Wrapper Migration Workflow.yml`](../workflows/Wrapper%20Migration%20Workflow.yml) — opens a PR rewriting callers off the deprecated NuGet / Internal NuGet / App Packages wrappers.

Do not duplicate this migration logic in other workflows; extend the existing migration workflow instead.

## Forbidden patterns

- `pull_request_target` triggers (the `guard-trigger` action fails the run).
- Third-party `uses:` pinned to a mutable ref — they must be pinned to a tag or full commit SHA.
- Interpolating `${{ inputs.* }}` or `${{ github.* }}` inside `.ps1` / `.sh` scripts invoked by composite actions.
- Passing secrets through `with:`.
- Echoing secrets to stdout.

## Org-level Copilot agent

A dedicated agent, **`skyline-workflow-author`** (in `SkylineCommunications/.github-private/agents/`), is the source-of-truth helper for authoring caller wrappers and editing this repo. Invoke it for non-trivial workflow/action changes; it enforces the two-phase plan/implement loop and links back to the two source-of-truth docs (this repo's `README.md`, `.github/actions/README.md`).
