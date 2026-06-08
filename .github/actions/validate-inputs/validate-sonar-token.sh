#!/usr/bin/env bash
# Validates that $SONAR_TOKEN is set.
set -euo pipefail

if [[ -n "$SONAR_TOKEN" ]]; then
  exit 0
fi

echo "Error: sonarCloudToken is not set."
echo "Please create a SonarCloud token by visiting: https://sonarcloud.io/account/security and copy the value of the created token."
repo_url="https://github.com/$REPO/settings/secrets/actions"
echo "Then set a SONAR_TOKEN secret in your repository settings: $repo_url"

if [[ "$HAS_DM_PROJECTS" == "true" ]]; then
  echo "Alternatively, if you do not wish to use the Skyline Quality Gate but intend to publish your results to the catalog, you may create your workflow to include the equivalent of a dotnet publish step as shown below:"
  echo "    - name: Publish"
  echo "      env:"
  echo "        api-key: \${{ secrets.DATAMINER_TOKEN }}"
  echo "      run: dotnet publish -p:Version=\"0.0.\${{ github.run_number }}\" -p:VersionComment=\"Iterative Development\" -p:CatalogPublishKeyName=api-key"
fi

exit 1
