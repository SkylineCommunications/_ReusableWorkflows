# determine-version

Determines the **single canonical build version** shared by every job in the Master Workflow, and a
strict 4-field numeric companion for consumers that reject SemVer suffixes.

- **Tag builds** use the tag name verbatim (e.g. `2.3.1`, `1.4.0-dev-myfeature.42`).
- **Branch builds** keep the legacy `0.0.<run-number>` in all modes.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `ref-type` | yes | The git ref type of the run (`github.ref_type`), `tag` or `branch`. |
| `ref-name` | yes | The git ref name of the run (`github.ref_name`). Used as the version on tag builds. |
| `run-number` | yes | The workflow run number (`github.run_number`). Used for the branch version and the 4th numeric field. |

## Outputs

| Output | Suffix allowed? | Description |
| --- | :--: | --- |
| `version` | ✔ | Full SemVer — for MSBuild `Version` / `PackageVersion`, NuGet, `.dmapp` / Catalog, `.deb` (after its own `~` normalisation), DxM release. |
| `numeric-version` | ✘ | Strict 4-field `major.minor.patch.<run-number>` (every field wrapped `% 65535`) — for `AssemblyVersion` / `FileVersion` and the WiX MSI `ProductVersion`. |

## Rules

- `numeric-version` = `version` with any pre-release/build suffix (`-…` / `+…`) stripped down to
  `major.minor.patch`, then `run-number` appended as the 4th field. An optional leading `v` on the
  tag is tolerated (and stripped).
- Assembly metadata restricts each version field to **65534** (`UInt16.MaxValue - 1` — every field
  must be strictly **less than 65535**), so **every field** of `numeric-version` is wrapped into
  range (`value % 65535`: 65534 → 65534, 65535 → 0, 65536 → 1) — a wrap-around, not a clamp, so the
  value keeps changing across runs. This also covers the legacy branch version `0.0.<run-number>`,
  whose patch field is the (unbounded) run number.
- A tag whose core is not `major.minor.patch` (e.g. `release-1`, `1.2`) fails the action with a
  clear error — such a version could not build anyway.
- **MSI caveat:** Windows Installer compares only the first **three** fields of `ProductVersion` for
  upgrade detection; the 4th (run number) is parsed but ignored. A real upgrade must still move
  `major.minor.patch` (the tag / auto-tag bump already does).

## Usage

```yaml
- name: Determine version
  id: determine-version
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/determine-version@main
  with:
    ref-type: ${{ github.ref_type }}
    ref-name: ${{ github.ref_name }}
    run-number: ${{ github.run_number }}
```

## Tests

`test.ps1` runs the version corpus offline (no git repository or network required):

```pwsh
pwsh -NoProfile -File ./test.ps1
```
