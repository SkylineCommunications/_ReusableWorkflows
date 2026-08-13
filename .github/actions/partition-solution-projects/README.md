# partition-solution-projects

Copies one `.sln`, `.slnx`, or `.slnf` file into three uniquely named sibling solutions so later jobs can process project categories independently. The source solution or filter and project files are never modified.

## Classification contract

- `wix`: projects whose file extension is `.wixproj`.
- `dataminer-package`: non-WiX projects whose XML explicitly contains a `GenerateDataMinerPackage` element with trimmed text equal to `true`, case-insensitively.
- `remaining`: every other project, including WiX custom-action `.csproj` projects, `DataMinerType` projects without an explicit true package flag, false values, expressions, missing elements, and values supplied only through imports.

The action fails closed when the source solution or a referenced project is missing, when a non-WiX project contains malformed XML, or when `dotnet sln list/remove` fails. Each output solution starts as a source copy, preserving solution configurations, folders, and project mappings for the projects it retains.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `solution-path` | yes | Path to the source `.sln`, `.slnx`, or `.slnf` file. |

## Outputs

| Output | Description |
| --- | --- |
| `remaining-solution-path` | Absolute path to the copied solution containing remaining projects. |
| `remaining-count` | Number of projects in the remaining partition. |
| `wix-solution-path` | Absolute path to the copied solution containing WiX projects. |
| `wix-count` | Number of projects in the WiX partition. |
| `dataminer-package-solution-path` | Absolute path to the copied solution containing DataMiner package projects. |
| `dataminer-package-count` | Number of projects in the DataMiner package partition. |

## Permissions

The action requires no elevated GitHub token permissions. A caller that checks out repository content can use:

```yaml
permissions:
  contents: read
```

## Usage

Run this after checkout and .NET SDK setup:

```yaml
- name: Partition solution projects
  id: partition
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/partition-solution-projects@main
  with:
    solution-path: src/Example.sln

- name: Build remaining projects
  if: steps.partition.outputs.remaining-count != '0'
  shell: pwsh
  env:
    SOLUTION_PATH: ${{ steps.partition.outputs.remaining-solution-path }}
  run: dotnet build $env:SOLUTION_PATH --configuration Release
```

Repeated invocations are safe: every invocation creates new GUID-qualified sibling solution names. Empty categories still produce usable zero-project solution files and report a count of `0`.

## Tests

The offline test scaffolds supported solution formats with the installed `dotnet` SDK and does not restore or build any project:

```pwsh
pwsh -NoProfile -File ./test.ps1
```
