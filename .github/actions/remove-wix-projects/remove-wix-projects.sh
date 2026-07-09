#!/usr/bin/env bash
# Removes WiX-related projects from the solution so the cross-platform ci job can
# build it (WiX cannot be built on Ubuntu, per the WiX maintainers; installers are
# built in the Windows packaging job instead):
#   * every *.wixproj
#   * every *.csproj that references WixToolset.Dtf.CustomAction or
#     WixToolset.Dtf.WindowsInstaller (WiX custom actions)
#
# Env (set by action.yml):
#   SOLUTION_PATH : path to the .sln/.slnx file.
#
# Outputs (written to $GITHUB_OUTPUT):
#   removed-count : number of projects removed.
set -euo pipefail

if [[ -z "${SOLUTION_PATH:-}" ]]; then
  echo "SOLUTION_PATH must be set." >&2
  exit 1
fi

solution_dir=$(dirname "$SOLUTION_PATH")
removed=0

# `dotnet sln list` prints a 2-line header before the project paths.
while IFS= read -r relative_path; do
  relative_path=${relative_path%$'\r'}  # tolerate CRLF output (Windows)
  [[ -z "$relative_path" ]] && continue
  relative_unix=${relative_path//\\//}
  absolute_path="$solution_dir/$relative_unix"

  remove=false
  if [[ "$relative_unix" == *.wixproj ]]; then
    remove=true
  elif [[ "$relative_unix" == *.csproj && -f "$absolute_path" ]] \
      && grep -qE 'WixToolset\.Dtf\.(CustomAction|WindowsInstaller)' "$absolute_path"; then
    remove=true
  fi

  if [[ "$remove" == "true" ]]; then
    echo "Removing WiX-related project from the solution: $relative_path"
    dotnet sln "$SOLUTION_PATH" remove "$absolute_path"
    removed=$((removed + 1))
  fi
done < <(dotnet sln "$SOLUTION_PATH" list | tail -n +3)

echo "Removed $removed WiX-related project(s)."
echo "removed-count=$removed" >> "$GITHUB_OUTPUT"
