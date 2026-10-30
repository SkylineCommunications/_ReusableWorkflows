# okf-source-sync

Detects changes to source files declared by existing OKF concepts.

This first increment is deliberately **detection-only**. It reads existing
concept front matter, compares same-repository immutable GitHub blob references
with the checked-out candidate commit, and writes a JSON report. It does not
generate content, create concepts, modify the checkout, or open pull requests.
Unsupported providers, moving references without an available immutable
baseline, and unavailable commits remain explicit diagnostics.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `okf-root` | no | `OKF` | Repository-relative OKF root. |
| `source-repository` | no | `${{ github.repository }}` | Full GitHub repository name whose source references are eligible. |
| `dry-run` | no | `true` | Records whether the detection is being run in report-only mode. This action is detection-only for either value. |
| `report-path` | no | `okf-source-sync-report.json` | JSON report path. |

## Outputs

| Output | Description |
| --- | --- |
| `status` | `no-change`, `changes-detected`, or `blocked`. |
| `affected-concepts` | Number of existing concepts affected by changed declared sources. |
| `report-path` | Absolute JSON report path. |

## Usage

```yaml
- name: Detect OKF source drift
  id: okf-sync
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/okf-source-sync@main
  with:
    okf-root: OKF
    source-repository: SkylineCommunications/internal-docs
    dry-run: 'true'
```

The caller must check out the repository with `fetch-depth: 0` (or otherwise
make every referenced reviewed commit available locally). Each source
reference must contain the full 40-character commit SHA of a commit object.
Missing or invalid baselines, external sources, and unsupported source
providers produce diagnostics and make the result `blocked`; any source-level
changes found before blocking remain in the report.

The `affected-concepts` output counts distinct concept paths. The JSON
`affected_concepts` array remains one entry per changed source so callers can
inspect each source that caused the impact.

The caller must run on a trusted branch and keep internal source content out of
public logs and artifacts. The action does not grant source permissions and does
not replace source-owner review.

## Local test

```powershell
pwsh .github/actions/okf-source-sync/test.ps1
```
