# quality-gate-summary

Composite action that aggregates the result of the standard Skyline CI
sub-gates (unit tests, SonarCloud, Validator) and:

1. Writes a Markdown summary to the GitHub Job Summary of the run.
2. Posts (or updates) a sticky PR comment with the same content when
   the workflow is triggered by a `pull_request` event.
3. Fails the job with a clear message when any sub-gate failed.

## Required caller permissions

To allow the sticky PR comment to be created/updated, the calling
workflow must grant:

```yaml
permissions:
  pull-requests: write
```

If the permission is missing, the comment step will fail; the rest of the
action still produces the Job Summary and enforces the gate.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `unit-tests-outcome` | yes | — | `steps.<id>.outcome` of the unit-tests step (`success` / `failure` / `skipped`). |
| `sonar-outcome` | no | `''` | `steps.<id>.outcome` of the SonarCloud Quality Gate step. Empty ⇒ row omitted. |
| `sonar-status` | no | `''` | `steps.<id>.outputs.quality-gate-status` (`OK` / `FAILED` / ...). |
| `validator-outcome` | no | `''` | `steps.<id>.outcome` of the Validator Quality Gate step. Empty ⇒ row omitted. |
| `validator-state-file` | no | `''` | Absolute path to `validator-gate-state.json` produced by the Validator Quality Gate step. When provided, a detailed table (current vs previous critical/major/minor) is rendered. |
| `major-change-checker-outcome` | no | `''` | `steps.<id>.outcome` of the Major Change Checker Quality Gate step. Empty ⇒ row omitted. |
| `major-change-checker-state-file` | no | `''` | Absolute path to `mcc-gate-state.json` produced by the Major Change Checker Quality Gate step. When provided, the sub-gate row reflects its skipped/passed/failed status. |
| `dependabot-bypass` | no | `'false'` | When `'true'` and `github.actor == 'dependabot[bot]'`, a failing SonarCloud gate is reported as a warning and does **not** fail the build. |
| `comment-header` | no | `'skyline-quality-gate'` | Header id used by the sticky PR comment (also embedded as an HTML marker in the body). |
| `post-pr-comment` | no | `'true'` | When `'true'`, post/update a sticky PR comment on `pull_request` events. Set to `'false'` to skip (e.g. self-tests without `pull-requests: write`). |

## Outputs

| Output | Description |
| --- | --- |
| `status` | `passed` or `failed`. |

## Usage

Minimal (unit tests + sonar only):

```yaml
- name: Quality Gate
  if: always()
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/quality-gate-summary@main
  with:
    unit-tests-outcome: ${{ steps.unit-tests.outcome }}
    sonar-outcome: ${{ steps.sonarcloud-quality-gate-check.outcome }}
    sonar-status: ${{ steps.sonarcloud-quality-gate-check.outputs.quality-gate-status }}
```

With the Validator (Connector Master SDK):

```yaml
- name: Quality Gate
  if: always()
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/quality-gate-summary@main
  with:
    unit-tests-outcome: ${{ steps.unit-tests.outcome }}
    sonar-outcome: ${{ steps.sonarcloud-quality-gate-check.outcome }}
    sonar-status: ${{ steps.sonarcloud-quality-gate-check.outputs.quality-gate-status }}
    validator-outcome: ${{ steps.validator-quality-gate.outcome }}
    validator-state-file: ${{ github.workspace }}/validator-gate-state.json
```

With the dependabot bypass (Master Workflow):

```yaml
- name: Quality Gate
  if: always()
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/quality-gate-summary@main
  with:
    unit-tests-outcome: ${{ steps.unit-tests.outcome }}
    sonar-outcome: ${{ steps.sonarcloud-quality-gate-check.outcome }}
    sonar-status: ${{ steps.sonarcloud-quality-gate-check.outputs.quality-gate-status }}
    dependabot-bypass: ${{ github.actor == 'dependabot[bot]' }}
```

> **Note**
> Always set `if: always()` on the calling step so the gate runs even
> when an earlier step failed — that's what makes the summary useful.
