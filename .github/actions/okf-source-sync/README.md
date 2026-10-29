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
| `dry-run` | no | `true` | Report-only mode. Keep enabled during the pilot. |
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

The caller must run on a trusted branch and keep internal source content out of
public logs and artifacts. The action does not grant source permissions and does
not replace source-owner review.

## Local test

```powershell
pwsh .github/actions/okf-source-sync/test.ps1
```
