#!/usr/bin/env bash
# Validates that $DATAMINER_TOKEN is set.
set -euo pipefail

if [[ -n "$DATAMINER_TOKEN" ]]; then
  exit 0
fi

echo "Error: dataminerToken is not set. Release not possible!"
echo "Please create or re-use an admin.dataminer.services token by visiting: https://admin.dataminer.services/."
echo "Navigate to the right organization, then go to Keys and create or find a key with the permissions Register catalog items, Download catalog versions, and Read catalog items."
echo "Copy the value of the token."
repo_url="https://github.com/$REPO/settings/secrets/actions"
echo "Then set a DATAMINER_TOKEN secret in your repository settings: $repo_url"
exit 1
