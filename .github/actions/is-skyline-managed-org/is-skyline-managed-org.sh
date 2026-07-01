set -euo pipefail

owner="${REPOSITORY_OWNER:-}"
managed_orgs_file="${MANAGED_ORGS_FILE:-$(dirname "$0")/managed-orgs.txt}"

if [[ -z "$owner" ]]; then
  echo "Input repository-owner is required." >&2
  exit 1
fi

if [[ ! -f "$managed_orgs_file" ]]; then
  echo "Managed organization list not found: $managed_orgs_file" >&2
  exit 1
fi

is_managed=false
while IFS= read -r managed_org || [[ -n "$managed_org" ]]; do
  [[ -z "$managed_org" || "$managed_org" == \#* ]] && continue
  if [[ "$owner" == "$managed_org" ]]; then
    is_managed=true
    break
  fi
done < "$managed_orgs_file"

echo "is-skyline-managed=$is_managed" >> "$GITHUB_OUTPUT"