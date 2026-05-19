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
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/<name>@<full-sha>
```

- Pin to a **full commit SHA**. Never `@main` for intra-repo composite references; pins are rewritten on merge by the maintenance script.
- The relative form `uses: ./.github/actions/<name>` is acceptable for the `guard-trigger` first step only, where SHA pinning would chicken-and-egg.

## Adding or editing composite actions (`.github/actions/<name>/`)

Mirrors [.github/actions/README.md](../actions/README.md):

1. **Folder layout**: `action.yml` + `run.ps1` and/or `run.sh`. Heavy logic lives in the scripts. The composite `run:` step should be a single line invoking the script.
2. **Naming**: kebab-case folder, kebab-case inputs and outputs. `name:` and `description:` are required on the action and on every input/output.
3. **Always set explicit `shell:`** on `run:` steps (`bash` or `pwsh`).
4. **Pass `${{ inputs.* }}` and `${{ github.* }}` through `env:`** — never interpolate them inside a script body. Reference them as shell variables (`$env:FOO` in pwsh, `$FOO` in bash).
5. **No secrets in `with:`** — pass tokens via `env:` to avoid logging.
6. **Outputs are surfaced through a step `id:`**, for example `value: ${{ steps.detect.outputs.test-runner-mode }}`.
7. **Idempotency** when the action mutates external state (NuGet sources, manifest files). Re-running the same step twice must not break.

## Migration workflows are part of the design

When touching anything that interacts with legacy paths, remember that two migration workflows exist and will run automatically:

- [`SDK Migration Workflow.yml`](../workflows/SDK%20Migration%20Workflow.yml) — opens an issue assigned to the Copilot coding agent when `Connector Master Workflow.yml` detects a legacy csproj on the default branch.
- [`Wrapper Migration Workflow.yml`](../workflows/Wrapper%20Migration%20Workflow.yml) — opens a PR rewriting callers off the deprecated NuGet / Internal NuGet / App Packages wrappers.

Do not duplicate this migration logic in other workflows; extend the existing migration workflows instead.

## Forbidden patterns

- `pull_request_target` triggers (the `guard-trigger` action fails the run).
- `@main` for intra-repo composite action references.
- Interpolating `${{ inputs.* }}` or `${{ github.* }}` inside `.ps1` / `.sh` scripts invoked by composite actions.
- Passing secrets through `with:`.
- Echoing secrets to stdout.
