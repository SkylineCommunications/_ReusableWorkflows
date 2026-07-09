# compute-next-version

Computes the next SemVer version from the latest **final** git tag and a `Change-Type` bump.

The action reads the repository tags, selects the highest `X.Y.Z` tag that has **no** pre-release
suffix, applies the requested `Major` / `Minor` / `Patch` bump, and (in `prerelease` mode) appends a
suffix. Pre-release tags are ignored when picking the base, so repeated pre-releases on a branch keep
bumping from the same final version.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `change-type` | no | The bump to apply: `Patch`, `Minor`, or `Major`. Empty resolves to `Patch`. |
| `mode` | no | `release` (bare version) or `prerelease` (suffix appended). Defaults to `release`. |
| `suffix` | no | Pre-release suffix body (e.g. `dev-myfeature.42`). Used only when `mode` is `prerelease`. |

## Outputs

| Output | Description |
| --- | --- |
| `version` | The computed version, e.g. `1.4.0` or `1.4.0-dev-myfeature.42`. |
| `latest-tag` | The latest final tag the bump was computed from, or empty when none exists. |

## Rules

- The base is the highest final tag matching `X.Y.Z` (an optional leading `v` is tolerated).
- Pre-release tags (anything containing `-`) are ignored when selecting the base.
- When no final tag exists the base is `0.0.0`, so a `Patch` bump yields `0.0.1`.
- `Major` → `X+1.0.0`, `Minor` → `X.Y+1.0`, `Patch` → `X.Y.Z+1`.
- `suffix` is ignored in `release` mode.

## Usage

```yaml
- name: Compute next version
  id: version
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/compute-next-version@main
  with:
    change-type: ${{ steps.references.outputs.change-type }}
    mode: prerelease
    suffix: dev-myfeature.42
```

The checkout that precedes this action must fetch tags (`fetch-depth: 0`) so the base tag can be
resolved.

## Tests

`test.ps1` runs the bump corpus offline by injecting a tag list via the `TAGS_OVERRIDE` environment
variable (so no git repository or network is required):

```pwsh
pwsh -NoProfile -File ./test.ps1
```
