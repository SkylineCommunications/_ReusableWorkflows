#!/usr/bin/env bash
# Validates that $SONAR_PROJECT_NAME is set. Prints a developer-friendly
# error pointing at the right settings page when it is not.
set -euo pipefail

if [[ -n "$SONAR_PROJECT_NAME" ]]; then
  exit 0
fi

echo "Error: sonarcloud-project-name is not set."
echo "Please create a SonarCloud project by visiting: https://sonarcloud.io/projects/create and copy the id of the project as mentioned in the sonarcloud project url."
repo_url="https://github.com/$REPO/settings/variables/actions"
echo "Then set a SONAR_NAME variable in your repository settings: $repo_url"

if [[ "$HAS_DM_PROJECTS" == "true" ]]; then
  echo "Alternatively, if you do not wish to use the Skyline Quality Gate but intend to publish your results to the catalog, you may create your workflow to include the equivalent of a dotnet publish step as shown below:"
  echo "    - name: Publish"
  echo "      env:"
  echo "        api-key: \${{ secrets.DATAMINER_TOKEN }}"
  echo "      run: dotnet publish -p:Version=\"0.0.$RUN_NUMBER\" -p:VersionComment=\"Iterative Development\" -p:CatalogPublishKeyName=api-key"
fi

exit 1
