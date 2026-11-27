#!/usr/bin/env bash
# Runs unit tests for every non-integration test project in the supplied
# solution. Dispatches on $TEST_RUNNER_MODE (`mtp` or `vstest`).
set -euo pipefail
shopt -s nocasematch nullglob

if [[ "$TEST_RUNNER_MODE" != "mtp" && "$TEST_RUNNER_MODE" != "vstest" ]]; then
  echo "Error: unsupported test-runner-mode '$TEST_RUNNER_MODE' (expected 'mtp' or 'vstest')." >&2
  exit 1
fi

case "${COVERAGE_MODE:-off}" in
  off) coverage_dir='' ;;
  report|upload) coverage_dir=$(mktemp -d "$RUNNER_TEMP/unit-test-coverage.XXXXXX") ;;
  *)
    echo "Error: unsupported coverage mode '$COVERAGE_MODE' (expected 'off', 'report', or 'upload')." >&2
    exit 1
    ;;
esac

native_path() {
  if [[ "${RUNNER_OS:-}" == 'Windows' ]]; then
    cygpath -am "$1"
  else
    printf '%s\n' "$1"
  fi
}

SOLUTION_DIR=$(dirname "${SOLUTION_PATH//\\//}")
projects=$(dotnet sln "$SOLUTION_PATH" list)
coverage_reports=()

while IFS= read -r project; do
  project="${project%$'\r'}"
  [[ "$project" =~ \.(cs|fs|vb)proj$ ]] || continue
  [[ "$project" != *"tests"* || "$project" == *"integrationtests"* || "$project" == *"integration.tests"* ]] && continue

  # `dotnet sln list` returns project paths relative to the solution file.
  project="${project//\\//}"
  if [[ "$project" != /* && "$project" != [A-Za-z]:/* ]]; then
    project="$SOLUTION_DIR/$project"
  fi

  results_args=()
  if [[ -n "$coverage_dir" ]]; then
    # Keep raw results in TestResults, but only merge coverage from this run.
    results_dir="$(cd "$(dirname "$project")" && pwd)/TestResults/${coverage_dir##*/}"
    results_args=(--results-directory "$(native_path "$results_dir")")
  fi

  if [[ "$TEST_RUNNER_MODE" == "mtp" ]]; then
    dotnet test --project "$project" \
      --no-build \
      --configuration "$CONFIGURATION" \
      "${results_args[@]}" \
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
      "${results_args[@]}" \
      --filter "TestCategory!=IntegrationTest&TestCategory!=IntegrationTests" \
      --logger "trx;logfilename=unitTestResults.trx" \
      --collect "XPlat Code Coverage" \
      -- DataCollectionRunSettings.DataCollectors.DataCollector.Configuration.Format=cobertura,opencover
  fi

  if [[ -n "$coverage_dir" ]]; then
    if [[ "$TEST_RUNNER_MODE" == "mtp" ]]; then
      reports=()
      if [[ -s "$results_dir/coverage.xml" ]]; then
        reports=("$results_dir/coverage.xml")
      fi
    else
      reports=("$results_dir"/*/coverage.cobertura.xml)
    fi
    if (( ${#reports[@]} == 0 )); then
      echo "Warning: no coverage report was produced for $project." >&2
    fi
    for report in "${reports[@]}"; do
      coverage_reports+=("$(native_path "$report")")
    done
  fi
done <<< "$projects"

if [[ -z "$coverage_dir" ]]; then
  exit 0
fi

if (( ${#coverage_reports[@]} == 0 )); then
  echo "::notice::No unit test coverage reports to publish."
  exit 0
fi

# Install outside the checkout so the tool does not depend on the solution's NuGet configuration.
(
  cd "$coverage_dir"
  dotnet tool install dotnet-reportgenerator-globaltool --version 5.6.1 \
    --tool-path tools --source https://api.nuget.org/v3/index.json
)
reports_arg=$(IFS=';'; printf '%s' "${coverage_reports[*]}")
"$coverage_dir/tools/reportgenerator" \
  "-reports:$reports_arg" \
  "-targetdir:$(native_path "$coverage_dir")" \
  "-sourcedirs:$(native_path "$GITHUB_WORKSPACE")" \
  -reporttypes:Cobertura

report="$coverage_dir/Cobertura.xml"
if [[ ! -s "$report" ]]; then
  echo "Error: the merged Cobertura report was not produced." >&2
  exit 1
fi
printf 'coverage-report=%s\n' "$(native_path "$report")" >> "$GITHUB_OUTPUT"
