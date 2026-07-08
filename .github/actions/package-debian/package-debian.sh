#!/usr/bin/env bash
# Builds one .deb per listed DxM project (ported from the Azure default-cd-linux.yml,
# restructured for multiple projects per repository):
#   * each project ships its own packaging skeleton at <project>/packaging/Debian/content/
#     (DEBIAN/{control,conffiles,preinst,postinst,prerm,postrm} + systemd unit);
#   * each project is staged in its OWN temp tree so multiple .debs never share or
#     clobber a single packaging/Debian/content;
#   * the project folder name is the Debian service name.
#
# Env (set by action.yml):
#   PROJECTS      : comma-separated project paths relative to the repo root.
#   VERSION       : canonical build version (Debian-normalised here: x.y.z-suffix -> x.y.z~suffix).
#   GENERATE_SBOM : 'true' => generate SBOM into usr/share/doc/skyline-communications-<name>.
#   CONFIGURATION : dotnet publish configuration.
#   OUTPUT_DIR    : directory receiving the built .deb files.
#
# Outputs (written to $GITHUB_OUTPUT):
#   package-count : number of .deb packages built.
set -euo pipefail

if [[ -z "${PROJECTS:-}" ]]; then
  echo "PROJECTS must be set." >&2
  exit 1
fi
if [[ -z "${VERSION:-}" ]]; then
  echo "VERSION must be set." >&2
  exit 1
fi
configuration="${CONFIGURATION:-Release}"
output_dir="${OUTPUT_DIR:-output}"

# --- Debian version normalisation -------------------------------------------------
# Pre-release x.y.z-suffix -> x.y.z~suffix (dashes inside the suffix removed; '~' sorts
# before the final release in dpkg ordering). Any character outside [A-Za-z0-9.~+] is
# stripped. Unlike the legacy Azure sed, dots are preserved.
raw_version="$VERSION"
if [[ "$raw_version" == *-* ]]; then
  prefix="${raw_version%%-*}"
  suffix="${raw_version#*-}"
  deb_version="${prefix}~${suffix//-/}"
else
  deb_version="$raw_version"
fi
deb_version=$(printf '%s' "$deb_version" | tr -cd 'A-Za-z0-9.~+')
if [[ -z "$deb_version" ]]; then
  echo "::error::Version '$raw_version' becomes empty after Debian sanitisation." >&2
  exit 1
fi
echo "Debian package version: $deb_version"

mkdir -p "$output_dir"
package_count=0

IFS=',' read -r -a projects <<< "$PROJECTS"
for project in "${projects[@]}"; do
  # Trim surrounding whitespace.
  project=$(printf '%s' "$project" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -z "$project" ]] && continue

  service_name=$(basename "$project")
  skeleton="$project/packaging/Debian"

  # 0. Validate: every listed project must ship the Debian skeleton.
  if [[ ! -f "$skeleton/content/DEBIAN/control" ]]; then
    echo "::error::Project '$project' is listed in dxm-projects-ubuntu but has no $skeleton/content/DEBIAN/control." >&2
    exit 1
  fi

  echo "── Packaging '$service_name' ──"
  staging=$(mktemp -d)

  # 1. Stage: copy the project's packaging skeleton into its own temp tree.
  cp -r "$skeleton" "$staging/Debian"
  content="$staging/Debian/content"

  # 2. Publish self-contained for linux-x64 into opt/skyline-communications/<name>.
  publish_dir="$content/opt/skyline-communications/$service_name"
  dotnet publish "$project" -c "$configuration" -r linux-x64 --self-contained true -o "$publish_dir"

  # 3. SBOM (full releases only): usr/share/doc/skyline-communications-<name>,
  #    matching the Azure reusable pipelines.
  if [[ "${GENERATE_SBOM:-false}" == "true" ]]; then
    sbom_dir="$content/usr/share/doc/skyline-communications-$service_name"
    mkdir -p "$sbom_dir"
    dataminer-sbom generate \
      --solution-path "$PWD" \
      --package-version "$raw_version" \
      --package-supplier "Skyline Communications" \
      --output "$sbom_dir"
  fi

  # 4. conffiles: copy each listed configuration file from the publish output to its
  #    target directory (ported from the Azure pipeline).
  conf_file="$content/DEBIAN/conffiles"
  if [[ -f "$conf_file" ]]; then
    while IFS= read -r line; do
      line=${line%$'\r'}
      [[ -z "$line" ]] && continue

      rel_path="${line#/}"
      file_name=$(basename "$rel_path")
      target_dir="$content/$(dirname "$rel_path")"
      publish_file="$publish_dir/$file_name"

      mkdir -p "$target_dir"
      if [[ -f "$publish_file" ]]; then
        echo "Copying conffile $file_name -> $target_dir"
        cp "$publish_file" "$target_dir"
      else
        echo "::warning::Expected conffile '$file_name' not found in the publish output of '$service_name'."
      fi
    done < "$conf_file"
  else
    echo "No conffiles file for '$service_name' - skipping."
  fi

  # 5. Version: substitute <VERSION> in DEBIAN/control.
  sed -i "s/<VERSION>/$deb_version/g" "$content/DEBIAN/control"

  # 6. Permissions: 755 for DEBIAN dir + maintainer scripts, 644 for control.
  chmod 755 "$content/DEBIAN"
  chmod 644 "$content/DEBIAN/control"
  for script in preinst postinst prerm postrm; do
    [[ -f "$content/DEBIAN/$script" ]] && chmod 755 "$content/DEBIAN/$script"
  done

  # 7. Build the package (dpkg-deb instead of FPM, see the Azure pipeline note).
  dpkg-deb --build "$content" "$output_dir/${service_name}_${deb_version}.deb"
  package_count=$((package_count + 1))

  rm -rf "$staging"
done

if [[ "$package_count" -eq 0 ]]; then
  echo "::error::No projects were packaged (projects input: '$PROJECTS')." >&2
  exit 1
fi

echo "Built $package_count Debian package(s) in $output_dir."
echo "package-count=$package_count" >> "$GITHUB_OUTPUT"
