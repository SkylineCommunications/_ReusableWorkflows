# determine-version

Determines the **single canonical build version** shared by every job in the Master Workflow, an exact
informational version, a strict 4-field numeric companion for assemblies, and an MSI-specific
ProductVersion.

- **Tag builds** use the tag name verbatim (e.g. `2.3.1`, `1.4.0-123.42.a1b2c3d4`).
- **Branch builds** keep the legacy `0.0.<run-number>` in all modes.
- **DataMiner package builds** use `package-version`, a normalized form that both the DataMiner package SDK and NuGet accept.

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
| `informational-version` | ✔ | Exact `AssemblyInformationalVersion`, equal to `version`; builds disable automatic source-revision appending. |
| `package-version` | ✔ | DataMiner package / NuGet `PackageVersion`. Stable versions pass through unchanged; pre-releases are reduced to `A.B.C-<alphanumeric>` (see rules). |
| `numeric-version` | ✘ | Strict 4-field `major.minor.patch.<build>` (every field wrapped `% 65535`) — for `AssemblyVersion` / `FileVersion`. `<build>` = the run number, or the version's own 4th field when it already has one. |
| `product-version` | ✘ | Stable three-part tags use `major.minor.build`; prereleases, branches, and explicit four-part tags retain `numeric-version`'s fourth field for Skyline release classification. |
| `product-version-valid` | — | `true` when MSI limits are met: major/minor ≤ 255 and build ≤ 65,535. |

## Rules

- `numeric-version` = `version` with any pre-release/build suffix (`-…` / `+…`) stripped down to the
  numeric core, then made 4-field. A 3-field core (`major.minor.patch` — SemVer tags) gets
  `run-number` appended as the 4th field; a **4-field core** (e.g. date-based tags like
  `2026.07.08.230`) **keeps its own 4th field** and the run number is not used. An optional leading
  `v` on the tag is tolerated (and stripped).
- Assembly metadata restricts each version field to **65534** (`UInt16.MaxValue - 1` — every field
  must be strictly **less than 65535**), so **every field** of `numeric-version` is wrapped into
  range (`value % 65535`: 65534 → 65534, 65535 → 0, 65536 → 1) — a wrap-around, not a clamp, so the
  value keeps changing across runs. This also covers the legacy branch version `0.0.<run-number>`,
  whose patch field is the (unbounded) run number.
- A tag whose core is not `major.minor.patch` or `major.minor.patch.build` (e.g. `release-1`, `1.2`)
  fails the action with a clear error — such a version could not build anyway.
- Stable three-part tags use the normalized three-field numeric core (`1.2.3`). Pre-release tags
  cannot carry their SemVer suffix in ProductVersion, so they use the suffix-free four-field
  `numeric-version` (`1.2.3-pr.run.sha` → `1.2.3.<workflow-run>`). Branch builds and explicit legacy
  four-part tags also retain that fourth field. Skyline tooling uses this shape to distinguish a
  prerelease/non-final package from a stable release.
- `informational-version` preserves the public version exactly, including a manual user suffix or the
  automatic `PR.RUN.SHA` suffix. The Master Workflow passes
  `IncludeSourceRevisionInInformationalVersion=false` so the SDK does not append another commit hash.
- MSI limits are independent from assembly limits: **major ≤ 255, minor ≤ 255, build ≤ 65,535**.
  `product-version-valid` exposes the result. The Master Workflow fails clearly on an invalid value
  only when a WiX project exists, so a non-MSI repository may still use a date-style tag such as
  `2026.07.08.230`.
- Windows Installer itself ignores the fourth field for upgrade comparison, so a real MSI upgrade
  must still change at least one of the first three fields. Retaining field four is a Skyline package
  convention; it does not change native MSI upgrade ordering.
- `package-version` exists because the DataMiner package SDK validates `PackageVersion` far more
  strictly than SemVer: it rejects the `.` and `-` separators a SemVer pre-release label may
  contain, rejects `+build` metadata, and rejects a four-field core combined with a suffix (despite
  its own error message listing `A.B.C.D-suffix` as supported). NuGet — which restores the very same
  projects — rejects `_`, so an underscore-normalised suffix fails `dotnet restore` with
  `MSB4181`. The only shape both tools accept is `A.B.C[.D]` or `A.B.C-<alphanumeric>`. Therefore
  build metadata is dropped, all separators inside the pre-release label are removed, and a
  four-field core with a suffix folds field four into the suffix
  (`1.2.3.4-rc.1+meta` → `1.2.3-4rc1`). **Stable versions are passed through untouched**, so a
  released package version still matches its tag exactly; only pre-releases are rewritten.

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
