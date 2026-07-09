# package-debian

Builds a Debian package (`.deb`) for each listed DxM project — the port of the Azure
`default-cd-linux.yml` packaging steps, restructured so **one repo can ship several `.deb`s**:

- each project ships its **own** packaging skeleton at
  `<project>/packaging/Debian/content/` (`DEBIAN/{control,conffiles,preinst,postinst,prerm,postrm}`
  + `lib/systemd/system/<service>.service`);
- each project is staged in its **own temp tree**, so multiple `.deb`s never share or clobber a
  single `packaging/Debian/content`;
- the **project folder name** is the Debian service name and install path
  (`opt/skyline-communications/<name>`).

Per project: validate skeleton → stage → `dotnet publish -r linux-x64 --self-contained` →
optional SBOM (`usr/share/doc/skyline-communications-<name>`, full releases) → copy `conffiles`
from the publish output → substitute `<VERSION>` in `DEBIAN/control` → fix permissions →
`dpkg-deb --build` → `<output>/<name>_<version>.deb`.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `projects` | yes | Comma-separated DxM project paths (relative to the repo root). |
| `version` | yes | Canonical build version (from `determine-version`). Debian-normalised here: `x.y.z-suffix` → `x.y.z~suffix` (dashes in the suffix removed, dots preserved). |
| `generate-sbom` | no | `'true'` ⇒ generate an SBOM per project (requires the `dataminer-sbom` tool on the PATH; full releases only). Default `'false'`. |
| `configuration` | no | `dotnet publish` configuration. Default `Release`. |
| `output-directory` | no | Directory receiving the `.deb` files. Default `output`. |

## Outputs

| Output | Description |
| --- | --- |
| `package-count` | Number of `.deb` packages built. Fails the action when 0. |

## Usage

```yaml
- name: Build Debian packages
  uses: SkylineCommunications/_ReusableWorkflows/.github/actions/package-debian@main
  with:
    projects: ${{ inputs.dxm-projects-ubuntu }}
    version: ${{ needs.determine_version.outputs.version }}
    generate-sbom: ${{ !contains(github.ref_name, '-') }}
```

## Tests

Covered by the `package-debian` job in
[`../../workflows/Test composite actions.yml`](../../workflows/Test%20composite%20actions.yml),
which scaffolds two console projects with Debian skeletons and asserts the built `.deb`s
(name, `~`-normalised version, publish output and conffile contents). `dpkg-deb` requires a
Linux runner, so there is no local `test.ps1`.
