# Copilot instructions — `_ReusableWorkflows`

Centralized GitHub Actions **reusable workflows** and **composite actions** consumed by 2000+ Skyline repositories. Changes here ship to the fleet on merge to `main`.

## Repository layout

- `.github/workflows/*.yml` — reusable workflows (`workflow_call`). Spaces in filenames are intentional and load-bearing.
- `.github/actions/<name>/` — composite actions. Each contains `action.yml` plus one or more scripts (`<name>.ps1`, `<name>.sh`, or task-named scripts like `load-from-keyvault.sh` + `apply-overrides.sh`).
- `.github/instructions/reusable-workflows.instructions.md` — authoring rules applied automatically when editing files under `.github/workflows/**` or `.github/actions/**`.
- `README.md` and `.github/actions/README.md` — public source-of-truth catalogs; keep in sync with reality when adding/renaming workflows or actions.

## Big-picture architecture

- **`Master Workflow.yml`** is the central CI/CD engine (build, validate, package, publish). Every new input scenario should go here.
- **`Connector Master Workflow.yml`** and **`Automation Master Workflow.yml`** auto-detect SDK vs. Legacy via `discover_projects` and dispatch to a sub-pipeline (`* SDK Workflow.yml` or `* Legacy Workflow.yml`). The two sub-pipelines are normally called only by their dispatcher, not directly.
- **Three deprecated wrappers** (`NuGet Solution Master Workflow.yml`, `Internal NuGet Solution Master Workflow.yml`, `DataMiner App Packages Master Workflow.yml`) are thin redirects to `Master Workflow.yml`. Do not extend them. Each calls `Wrapper Migration Workflow.yml` on non-PR runs, which opens a PR in the caller repo rewriting it to call `Master Workflow.yml` directly.
- **`Update Catalog Details Workflow.yml`** updates DataMiner Catalog metadata on release.
- **OIDC + Key Vault flow:** the first jobs of every master workflow run `guard-trigger` → `resolve-oidc` → (per job) `load-secrets`. `resolve-oidc` returns Skyline defaults for owners allowed by `is-skyline-managed-org`, caller-provided values otherwise, or `use-oidc=false` (which makes downstream Key Vault loading a no-op). Forked PRs force `use-oidc=false`. OIDC parameters flow top-down through `with:` to sub-pipelines.
- **Migration workflow is part of the design.** Don't reimplement caller-rewriting logic elsewhere; extend `Wrapper Migration Workflow.yml`. The default `GITHUB_TOKEN` cannot push files under `.github/workflows/`, so this workflow fetches a user-owned PAT from Azure Key Vault via OIDC.

## Hard conventions (enforced or load-bearing)

- **First step of every reusable workflow is `guard-trigger`** (rejects `pull_request_target`). Use the relative form `uses: ./.github/actions/guard-trigger` only for this one step — it's the chicken-and-egg exception that the `instructions.md` calls out.
- **Pin policy:** intra-repo composite references and caller workflows currently use `@main`; that is the de facto convention across the fleet (and what every workflow in this repo uses today). Third-party `uses:` (e.g. `actions/checkout@v6`, `azure/login@...`) must still be pinned to a tag or full commit SHA.
- **`pull_request_target` is forbidden everywhere.**
- **Secrets travel via `env:`, never `with:`.** Never echo a secret.
- **In composite scripts, never interpolate `${{ inputs.* }}` or `${{ github.* }}` inside the script body.** Pass them through `env:` and reference as shell variables (`$env:FOO` in pwsh, `$FOO` in bash).
- **`shell:` is always explicit** on `run:` steps (`bash` or `pwsh`).
- **Every composite input and output has a `description:`.**
- **Job-scoped, least-privilege `permissions:`** starting from `contents: read`. Add `id-token: write` only when OIDC is needed.
- **Composite actions that mutate external state must be idempotent** (re-running must not break). `Test composite actions.yml` has explicit idempotency assertions for `setup-nuget-sources` and `update-global-json-sdks`.

## Centrally-managed SDK versions

`update-global-json-sdks/action.yml` hard-codes `$DATAMINER_SDK_VERSION` and the `$dataMinerSdkPatterns` list. **To roll out a new DataMiner SDK version across the fleet, bump that constant and the matching `version=...` line in the `update-global-json-sdks` job of `Test composite actions.yml`.** The action rewrites every `msbuild-sdks` key matching `Skyline.DataMiner.*` to the shared version; exact-name overrides in `$otherManagedSdks` win against the pattern.

## DxM and DcM integration boundary

This repository owns only the reusable, repository-type-neutral part of the DxM flow:

- `Master Workflow.yml` builds, tests, packages, signs, and publishes artifacts.
- `compute-next-version`, `determine-version`, and `exempt-change-detector` provide shared release classification and version contracts.
- `references-parser` parses the common `References:` administration format.
- `package-debian`, `resolve-oidc`, `load-secrets`, NuGet-source actions, and `set-repo-type` remain generic building blocks.

Core-specific PR governance, tag orchestration, collaboration, CR/QA task-state behavior, and the production DxM repository template belong in `SkylineCommunicationsCore/.github-private`. SkylineAPI behavior belongs in `SkylineCommunicationsCore/Skyline.DataMiner.CICD.Tools.ReleaseTracker`. DxM artifact API behavior and the production server synchronizer belong in `SkylineCommunicationsCore/Skyline.DataMiner.CICD.Tools.DxMStorage`.

When changing a DxM-facing contract:

- Search `SkylineCommunicationsCore/.github-private/provisioning/dxm-repo-template` and its reusable workflows for affected callers and consumers.
- Keep stable and prerelease SemVer behavior aligned across `compute-next-version`, `determine-version`, `.github-private/auto-tag.yml`, DxMStorage publication, and server tag resolution.
- Keep exempt-change behavior aligned between `exempt-change-detector`, `.github-private/pr-validation.yml`, `.github-private/auto-tag.yml`, `.github-private/collaboration.yml`, and ReleaseTracker's reserved-RN filtering.
- Add or update `Test composite actions.yml` coverage for a changed action, then use the downstream battery for the affected Master Workflow paths. Event-driven Core governance behavior still needs a separate `PilotDxM` run.
- Update `SkylineCommunications/internal-docs/DevDocs/GitHub_DxM_Repositories/` when developer, release, packaging, identity, or operational behavior changes.

## Testing

- **`Test composite actions.yml`** — self-contained smoke tests, triggered on push/PR that touches `.github/actions/**`. Adds runtime assertions on outputs and idempotency for every composite that doesn't need live secrets. When you add a composite action, **add a matching job here**. `sonarcloud-status` is gated to `workflow_dispatch` because it needs a live `SONAR_TOKEN` + `SONAR_NAME` var.
- **Downstream integration-test battery** — source of truth: [TESTING.md](../TESTING.md). `Downstream Gate.yml` posts the `downstream-tests` commit status on every PR (pending when workflows/actions are touched). A `/test` comment (write access) runs `Test Downstream.yml`: it maps changed workflows *and composite actions* to consumer repos via `DOWNSTREAM_MAP`, force-pushes the `test-downstream` tag, dispatches the `BOOST-DailyRegression-*` receivers (`pr-regression.yml`, correlation-id + tag-SHA verified), polls up to 90 min, and finalizes the commit status. `/retest` re-dispatches only the repos that failed in the previous battery (state embedded in the sticky comment; requires an unchanged head SHA). Downstream verify jobs assert artifact/job names — see "Downstream battery coupling" in `.github/instructions/reusable-workflows.instructions.md` before renaming anything. **When adding a new downstream repo:** follow the checklist in TESTING.md (fixtures validated locally, receiver, secrets, repo topic, `DOWNSTREAM_MAP` entry incl. transitive workflow dependencies).
- **Cross-repository fixes** — Copilot autofix cannot edit a battery repository from a `_ReusableWorkflows` review session. When a review finding requires downstream changes, name the affected mapped repositories and provide a ready-to-run `/prepare-downstream-fixes` comment with concrete acceptance criteria. A maintainer must post it; the command creates linked downstream issues and assigns separate Copilot sessions. Never claim the source autofix will make those changes itself.
- **`/test` runs `main`'s orchestrator** (`issue_comment` semantics) — changes to `Test Downstream.yml` itself only take effect after merge.
- **Maintenance script tests** — run `python -m unittest discover -s .github/scripts/tests -p 'test_*.py'` locally. Validate reusable-workflow behavior by pushing a branch and `/test`-ing a PR for downstream coverage.

## When making changes

- **New input scenarios → extend `Master Workflow.yml`**, not a new wrapper. The three deprecated wrappers stay frozen.
- **Adding a composite action:** create `.github/actions/<name>/` with `action.yml` + named script(s); add a row to `.github/actions/README.md`; add a smoke-test job to `Test composite actions.yml`; reference it from the relevant master workflow with `@main`.
- **Editing the SDK version constant** in `update-global-json-sdks/action.yml`: also update the expected `version=` in `Test composite actions.yml` or its assertion will fail.
- **Editing `Test Downstream.yml`'s `DOWNSTREAM_MAP`**: each entry lists *all* workflow files whose change should fan out to that downstream — include both the entry-point workflow and any sub-pipeline it dispatches to.
- **Spaces in workflow filenames**: both `Master Workflow.yml` and `Master%20Workflow.yml` work in `uses:`; the repo uses literal spaces.

## Org-level Copilot agent

A dedicated agent, **`skyline-workflow-author`** (in `SkylineCommunications/.github-private/agents/`), is the source-of-truth helper for authoring caller wrappers and editing this repo. Invoke it for non-trivial workflow/action changes; it enforces the two-phase plan/implement loop and links back to the three source-of-truth docs (this repo's `README.md`, `.github/actions/README.md`, and `.github/instructions/reusable-workflows.instructions.md`).
