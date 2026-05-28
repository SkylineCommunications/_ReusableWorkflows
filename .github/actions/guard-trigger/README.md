# guard-trigger

Fails a workflow when triggered through `pull_request_target`.

Use this as the first step of reusable workflows that should not run with elevated permissions on untrusted PR content.

## Inputs

No inputs.

## Outputs

No outputs.

## Used by

- All master and wrapper workflows under [../../workflows](../../workflows)
- [Test composite actions.yml](../../workflows/Test%20composite%20actions.yml)

## Usage

### Basic

```yaml
- uses: SkylineCommunications/_ReusableWorkflows/.github/actions/guard-trigger@main
```

### Local (relative) form

```yaml
- uses: ./.github/actions/guard-trigger
```

## Notes

- Keep this as the first step in reusable workflows.
- The action is intentionally minimal and inline in `action.yml`.
