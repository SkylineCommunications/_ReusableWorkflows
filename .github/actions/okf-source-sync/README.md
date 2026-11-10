# okf-source-sync

Detects changes to source files declared by existing OKF concepts.

This first increment is deliberately **detection-only**. It reads existing
concept front matter, compares same-repository immutable GitHub blob references
with the checked-out candidate commit, and writes a JSON report. It does not
generate content, create concepts, or open pull requests. Writing the report is
the only file mutation, and it occurs for either `dry-run` value; callers must
choose a report destination that is not a source or OKF input file.
Unsupported providers, moving references without an available immutable
baseline, unavailable commits, and unsupported or malformed source
declarations remain explicit diagnostics.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `okf-root` | no | `OKF` | Repository-relative OKF root. |
| `source-repository` | no | `${{ github.repository }}` | Full GitHub repository name whose source references are eligible. |
| `dry-run` | no | `true` | Records whether detection is being run in report-only mode. Both values remain detection-only; both write the report. |
| `report-path` | no | `okf-source-sync-report.json` | JSON report path. Use a separate path such as `${{ runner.temp }}/okf-source-sync-report.json`; the action overwrites its destination on each run. |
| `changed-files` | no | empty | Newline-delimited paths from the triggering PR. When supplied, only these paths are considered; include both names for renames. |
| `candidate-commit` | no | checked-out `HEAD` | Commit containing the merged PR snapshot. |

## Outputs

| Output | Description |
| --- | --- |
| `status` | `no-change`, `changes-detected`, or `blocked`. |
| `affected-concepts` | Number of existing concepts affected by changed declared sources. |
| `report-path` | Absolute JSON report path. |
| `changed-files` | Number of supplied changed paths. |

## Usage

```yaml
- name: Detect OKF source drift
  id: okf-sync
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/okf-source-sync@main
  with:
    okf-root: OKF
    source-repository: SkylineCommunications/internal-docs
    dry-run: 'true'
    report-path: ${{ runner.temp }}/okf-source-sync-report.json
```

The caller must check out the repository with `fetch-depth: 0` (or otherwise
make every referenced reviewed commit available locally). Each source
reference must contain the full 40-character commit SHA of a commit object.
Missing or invalid baselines, external sources, and unsupported source
providers produce diagnostics and make the result `blocked`; source-level
changes found before blocking remain in the report.

The action parses YAML front matter with the pinned `PyYAML==6.0.3`
dependency. It supports block-style and flow-style `sources` lists whose
entries contain a string `resource`. Malformed YAML, duplicate mapping keys,
unsupported source entry shapes, and missing or non-string resources produce
blocking diagnostics instead of being treated as an empty source list.
Python 3.8 or later, `pip`, and access to install the pinned package are
required. The package is installed into a runner-temporary directory and is
not added to the caller workspace or global Python environment.

The caller job needs `contents: read` for its checkout. No additional token,
write, or OIDC permission is required by this action itself.

The `affected-concepts` output counts distinct concept paths. The JSON
`affected_concepts` array remains one entry per changed source so callers can
inspect each source that caused the impact.

For merged-PR workflows, pass the verified PR file list through `changed-files`
and the merge commit through `candidate-commit`. The JSON `changed_paths` array
is preserved for a semantic stage to inspect changed source content that is not
yet referenced by an existing concept. When `changed-files` is omitted, the
original repository-wide detection behavior is retained.

The caller must run on a trusted branch and keep internal source content out of
public logs and artifacts. The action does not grant source permissions and does
not replace source-owner review. The report path is not protected from
colliding with a declared source or OKF file, so callers are responsible for
choosing a safe destination.

## Local test

```powershell
pwsh .github/actions/okf-source-sync/test.ps1
```
