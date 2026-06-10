---
description: "Conventions for editing reusable workflows and composite actions inside SkylineCommunications/_ReusableWorkflows."
applyTo: ".github/workflows/**,.github/actions/**"
---

# `_ReusableWorkflows` authoring conventions

This file applies when editing workflows under `.github/workflows/` or composite actions under `.github/actions/` **inside the `_ReusableWorkflows` repo**. For broader org-wide guidance on consuming these workflows from caller repos, the `skyline-workflow-author` Copilot agent (org-level) is the source of truth.

## Source-of-truth references

- Master workflow catalog and deprecation rules: [README.md](../../README.md)
- Composite action conventions: [.github/actions/README.md](../actions/README.md)

## Editing reusable workflows (`.github/workflows/*.yml`)

- **Do not add another wrapper workflow.** New input scenarios go into [`Master Workflow.yml`](../workflows/Master%20Workflow.yml). The three deprecated wrappers (`NuGet Solution Master Workflow.yml`, `Internal NuGet Solution Master Workflow.yml`, `DataMiner App Packages Master Workflow.yml`) are kept only as redirects; do not extend them.
- **First step is `guard-trigger`** (or its SHA-pinned external form). It rejects `pull_request_target`.
- **OIDC parameters flow top-down.** Resolve once via `resolve-oidc` and pass `oidc-client-id` / `oidc-tenant-id` / `oidc-subscription-id` / `use-oidc` through to any sub-workflow that needs Key Vault access.
- **Secrets travel via `env:`, never `with:`.** Never log secrets.
- **Job-scoped `permissions:`** — start from the least set the job needs (`contents: read` minimum) and add only what is required.

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
