#!/usr/bin/env bash
# Queries the SonarCloud quality-gate status API for $SONAR_PROJECT_NAME on
# $BRANCH_NAME, validates the response, and writes `needsInitialAnalysis=true|false`
# to $GITHUB_OUTPUT.
set -euo pipefail

sonarCloudProjectStatus=$(curl -s -u "$SONAR_TOKEN:" "https://sonarcloud.io/api/qualitygates/project_status?projectKey=$SONAR_PROJECT_NAME&branch=$BRANCH_NAME")

if [ -z "$sonarCloudProjectStatus" ] || ! echo "$sonarCloudProjectStatus" | jq . > /dev/null 2>&1; then
  echo "Error: The SONAR_TOKEN is invalid, expired, or the response is empty. Please check: https://sonarcloud.io/account/security and update your token: https://github.com/$REPO/settings/secrets/actions" >&2
  echo "Returned response: $sonarCloudProjectStatus" >&2
  exit 1
fi

if echo "$sonarCloudProjectStatus" | jq -e '.errors' > /dev/null 2>&1; then
  echo "Error: SonarCloud API returned errors. Initial analysis needed." >&2
  echo "Returned response: $sonarCloudProjectStatus" >&2
  echo "needsInitialAnalysis=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

projectStatus=$(echo "$sonarCloudProjectStatus" | jq -r '.projectStatus.status // empty')
if [ "$projectStatus" = "NONE" ]; then
  echo "Project status is NONE. Initial analysis needed."
  echo "needsInitialAnalysis=true" >> "$GITHUB_OUTPUT"
else
  echo "needsInitialAnalysis=false" >> "$GITHUB_OUTPUT"
fi

echo "Returned response: $sonarCloudProjectStatus"
