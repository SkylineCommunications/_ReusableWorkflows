# exempt-change-detector

Classifies a pull request as an **exempt change** when *every* changed file matches one of the
configured glob patterns. Exempt PRs (by default those touching only GitHub configuration or unit-test
projects) do not require a task id and can have a predefined RN auto-added by the caller workflow, so
the mandatory PR-validation gate and the commit-metadata ruleset stay satisfied without manual RN/Task
administration.

The Core DxM validation caller currently uses `RN46090` for this purpose. It is a validation-only
reference: it remains in PR and squash-commit metadata, while the full-release collaboration workflow
and ReleaseTracker server sync exclude it from Release Note mutations. The automatic-release workflow
also uses this classification to skip its merge tag when all changed files are exempt. Explicit real RNs
and mixed/source file changes remain actionable; an explicitly requested prerelease is unaffected.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `changed-files` | yes | Newline-separated list of file paths changed in the pull request. |
| `patterns` | no | Newline-separated glob patterns. Defaults to `.github/**`, `**/*Tests/**`, `**/*.Tests/**`. |

## Repository patterns

A repository can add exempt paths in `.github/exempt-change-patterns.txt`, with one glob per line:

```text
# Local-only development tools
tools/LocalHarness/**
```

The file is optional. Its patterns augment rather than replace the `patterns` input. Blank lines and
lines whose first non-whitespace character is `#` are ignored.

The action reads this file from `GITHUB_WORKSPACE`, so the caller must check out the repository before
invoking it. For pull-request governance, check out the trusted base revision rather than the PR head;
otherwise a PR could widen its own exemptions. A new repository pattern then takes effect after the
configuration change is merged.

Repository patterns must be relative, use `/` as the separator, and cannot use negation, `.` or `..`
segments, or the repository-wide `**` pattern. Invalid configuration fails the action.

## Outputs

| Output | Description |
| --- | --- |
| `exempt` | `true` when at least one file changed and every changed file matches a pattern; otherwise `false`. |

## Rules

- A PR is exempt only when **at least one** file changed **and every** changed file matches a pattern.
- An **empty** change set is never exempt (so it can never trigger the auto-RN injection).
- Patterns support `*` (any run of non-separator characters), `?` (one non-separator character), and
  `**` (any characters including `/`). `**/` matches zero or more leading path segments.
- Matching is case-insensitive.

## Glob semantics

| Pattern | Matches | Does not match |
| --- | --- | --- |
| `.github/**` | `.github/workflows/ci.yml`, `.github/dependabot.yml` | `docs/.github/x` |
| `**/*Tests/**` | `src/MyProjectTests/Foo.cs`, `src/My.Tests/Foo.cs` | `FooTests.cs` (no folder) |
| `**/*.Tests/**` | `src/My.Tests/Foo.cs` | `src/Testing/Foo.cs` |

## Usage

```yaml
- name: Check out trusted repository configuration
  uses: actions/checkout@v7
  with:
    ref: ${{ github.event.pull_request.base.sha }}

- name: Collect changed files
  id: changed
  shell: bash
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    files="$(gh api --paginate "repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/files" --jq '.[].filename')"
    {
      echo "files<<__FILES_EOF__"
      echo "$files"
      echo "__FILES_EOF__"
    } >> "$GITHUB_OUTPUT"

- name: Classify exempt change
  id: exempt
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/exempt-change-detector@main
  with:
    changed-files: ${{ steps.changed.outputs.files }}
```
