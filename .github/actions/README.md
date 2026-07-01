# Composite actions

Shared building blocks for the reusable workflows in
[`../workflows/`](../workflows/).

Each action lives in its own folder and follows the same layout:

```text
.github/actions/<name>/
  action.yml          # declares inputs, outputs, and the runs: using: composite block
  <name>.ps1          # (optional) PowerShell logic invoked by the composite
  <name>.sh           # (optional) bash logic invoked by the composite
```

Larger actions may have multiple scripts named after their sub-tasks (e.g. `load-secrets` ships `load-from-keyvault.sh` + `apply-overrides.sh`). Small actions whose only logic is a single `echo` + `exit` (e.g. `guard-trigger`) may keep that one-liner inline in `action.yml`.

## Conventions

- **Heavy logic lives in `.ps1` / `.sh` files** named after the action (or its sub-tasks), not inline YAML. Composite `run:` steps should be a single line that invokes the script. This keeps the logic testable outside of GitHub Actions and makes diffs readable.
- **No secrets in `with:`** — pass tokens via `env:` to avoid logging.
- **Inputs use `kebab-case`**, outputs use `kebab-case`.
- **Every input and output has a `description:`.**
- **Never interpolate `${{ inputs.* }}` or `${{ github.* }}` directly
  inside a script body.** Pass them through `env:` and reference as
  shell variables.
- **`shell:` is always explicit** on `run:` steps (`bash` or `pwsh`).

## Catalog

Usage examples in each action README are sourced from the master workflows in
[`../workflows/`](../workflows/) and from
[`../workflows/Test composite actions.yml`](../workflows/Test%20composite%20actions.yml).

| Action | What it does | Docs |
| --- | --- | --- |
| `guard-trigger` | Blocks unsupported `pull_request_target` executions. | [guard-trigger/README.md](guard-trigger/README.md) |
| `is-skyline-managed-org` | Checks whether a repository owner is Skyline-managed. | [is-skyline-managed-org/README.md](is-skyline-managed-org/README.md) |
| `resolve-oidc` | Resolves Azure OIDC values and exposes `use-oidc`. | [resolve-oidc/README.md](resolve-oidc/README.md) |
| `load-secrets` | Loads Key Vault secrets and applies caller overrides. | [load-secrets/README.md](load-secrets/README.md) |
| `add-github-nuget-source` | Registers a GitHub Packages NuGet source. | [add-github-nuget-source/README.md](add-github-nuget-source/README.md) |
| `add-azure-nuget-source` | Registers an Azure DevOps NuGet source by URL. | [add-azure-nuget-source/README.md](add-azure-nuget-source/README.md) |
| `setup-nuget-sources` | Registers GitHub and optional Skyline NuGet feeds. | [setup-nuget-sources/README.md](setup-nuget-sources/README.md) |
| `setup-skyline-nuget-sources` | Registers all Skyline GitHub and Azure NuGet feeds. | [setup-skyline-nuget-sources/README.md](setup-skyline-nuget-sources/README.md) |
| `validate-inputs` | Validates mandatory Sonar/DataMiner inputs based on context. | [validate-inputs/README.md](validate-inputs/README.md) |
| `update-global-json-sdks` | Rewrites managed `msbuild-sdks` versions in `global.json`. | [update-global-json-sdks/README.md](update-global-json-sdks/README.md) |
| `apply-catalog-identifiers` | Rewrites manifest `id:` fields from mapping input. | [apply-catalog-identifiers/README.md](apply-catalog-identifiers/README.md) |
| `apply-source-code-url` | Fills empty `source_code_url:` fields in catalog manifests. | [apply-source-code-url/README.md](apply-source-code-url/README.md) |
| `sonarcloud-status` | Checks SonarCloud project status and emits analysis flag. | [sonarcloud-status/README.md](sonarcloud-status/README.md) |
| `detect-test-runner` | Detects MTP or VSTest mode from `global.json`. | [detect-test-runner/README.md](detect-test-runner/README.md) |
| `run-unit-tests` | Runs unit tests for all test projects in a solution. | [run-unit-tests/README.md](run-unit-tests/README.md) |
| `unit-tests` | Wrapper combining detect + run unit test actions. | [unit-tests/README.md](unit-tests/README.md) |
| `quality-gate-summary` | Aggregates unit-test / SonarCloud / Validator outcomes, renders a Job Summary + sticky PR comment, and fails the job on any failed sub-gate. | [quality-gate-summary/README.md](quality-gate-summary/README.md) |

## Referencing from a reusable workflow in this repo

Composite actions are an implementation detail of the reusable
workflows. When a reusable workflow consumes one, reference it relative
to the repository root and pin to `@main` — this matches the convention
used across every workflow in this repo and the wider Skyline fleet:

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/guard-trigger@main
```

Third-party `uses:` (e.g. `actions/checkout@v6`) must still be pinned to
a tag or full commit SHA.
