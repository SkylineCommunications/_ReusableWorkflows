# Composite actions

Shared building blocks for the reusable workflows in
[`../workflows/`](../workflows/).

Each action lives in its own folder and follows the same layout:

```
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

## Referencing from a reusable workflow in this repo

Composite actions are an implementation detail of the reusable
workflows. When a reusable workflow consumes one, reference it relative
to the repository root and pin to a full commit SHA so that callers who
pin the reusable workflow to a specific SHA get a fully reproducible
run:

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/guard-trigger@<full-sha>
```

The pins are rewritten on merge by the maintenance script (see plan).
Do not use `@main` for intra-repo composite references.
