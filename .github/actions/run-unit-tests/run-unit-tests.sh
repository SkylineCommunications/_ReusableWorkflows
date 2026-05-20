#!/usr/bin/env bash
# Runs unit tests for every non-integration test project in the supplied
# solution. Dispatches on $TEST_RUNNER_MODE (`mtp` or `vstest`).
set -euo pipefail
shopt -s nocasematch

if [[ "$TEST_RUNNER_MODE" != "mtp" && "$TEST_RUNNER_MODE" != "vstest" ]]; then
  echo "Error: unsupported test-runner-mode '$TEST_RUNNER_MODE' (expected 'mtp' or 'vstest')." >&2
  exit 1
fi

SOLUTION_DIR=$(dirname "$SOLUTION_PATH")

while IFS= read -r project; do
  [[ "$project" != *"tests"* || "$project" == *"integrationtests"* || "$project" == *"integration.tests"* ]] && continue

  # `dotnet sln list` returns project paths relative to the solution file.
  # Resolve them against the solution directory so the script works from
  # any CWD.
  if [[ "$project" != /* ]]; then
    project="$SOLUTION_DIR/$project"
  fi

  if [[ "$TEST_RUNNER_MODE" == "mtp" ]]; then
    dotnet test --project "$project" \
      --no-build \
      --configuration "$CONFIGURATION" \
      --filter "TestCategory!=IntegrationTest&TestCategory!=IntegrationTests" \
      --report-trx \
      --report-trx-filename unitTestResults.trx \
      --coverage \
      --coverage-output-format xml \
      --coverage-output coverage.xml \
      --ignore-exit-code 8
  else
    dotnet test "$project" \
      --no-build \
      --configuration "$CONFIGURATION" \
      --filter "TestCategory!=IntegrationTest&TestCategory!=IntegrationTests" \
      --logger "trx;logfilename=unitTestResults.trx" \
      --collect "XPlat Code Coverage" \
      -- DataCollectionRunSettings.DataCollectors.DataCollector.Configuration.Format=cobertura,opencover
  fi
done < <(dotnet sln "$SOLUTION_PATH" list | tail -n +3 | grep -E '\.(cs|fs|vb)proj$')
