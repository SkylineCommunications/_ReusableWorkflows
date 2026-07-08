# remove-wix-projects

Strips WiX-related projects from a solution so the **cross-platform `ci` job** can build it — WiX
cannot be built on Linux (per the WiX maintainers). The real installer build happens in the Windows
packaging job, which builds the **unmodified** solution.

Removed from the solution:

- every `*.wixproj`;
- every `*.csproj` that references `WixToolset.Dtf.CustomAction` or
  `WixToolset.Dtf.WindowsInstaller` (WiX custom actions — they only exist to be embedded in the MSI).

The projects are only removed from the **solution file** in the runner's workspace; nothing is
deleted from disk or committed.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `solution-path` | yes | Path to the solution file (`.sln` / `.slnx`) to strip. |

## Outputs

| Output | Description |
| --- | --- |
| `removed-count` | The number of WiX-related projects removed. `0` when nothing matched (idempotent). |

## Usage

```yaml
- name: Remove WiX projects (not buildable in cross-platform CI)
  if: needs.discover_projects.outputs.has-wix-projects == 'true'
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/remove-wix-projects@main
  with:
    solution-path: ${{ needs.discover_projects.outputs.solution-path }}
```

## Tests

`test.ps1` scaffolds a temporary solution (plain libs + a `.wixproj` + a `WixToolset.Dtf`
custom-action `.csproj`) with the `dotnet` CLI, runs the script, and asserts only the WiX-related
projects were removed (plus an idempotent re-run):

```pwsh
pwsh -NoProfile -File ./test.ps1
```
