import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


WORKFLOW = Path(__file__).resolve().parents[3] / ".github/workflows/Connector Master SDK Workflow.yml"
STEPS = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["validate_skyline_quality_gate"]["steps"]
POWERSHELL = shutil.which("pwsh")
BASH = shutil.which("bash") or next(
    (str(path) for path in (Path("C:/Program Files/Git/bin/bash.exe"),) if path.is_file()),
    None,
)
JQ = shutil.which("jq")


def workflow_step(name):
    return next(step for step in STEPS if step.get("name") == name)


class ConnectorCompareExceptionTests(unittest.TestCase):
    @unittest.skipUnless(POWERSHELL, "PowerShell is required")
    def test_key_vault_match_is_exact_and_optional(self):
        script = workflow_step("Check connector compare exception")["run"]
        self.assertEqual("inputs.use-oidc == 'true'", workflow_step("Check connector compare exception")["if"])

        az_stub = """
function az {
  if ($env:AZ_MODE -eq 'missing') { $global:LASTEXITCODE=1; Write-Output '(SecretNotFound) missing'; return }
  if ($env:AZ_MODE -eq 'error') { $global:LASTEXITCODE=1; Write-Output '(Forbidden) denied'; return }
  $global:LASTEXITCODE=0
  Write-Output (ConvertTo-Json -Compress -InputObject $env:AZ_VALUE)
}
$global:LASTEXITCODE=0
"""

        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            solution = directory / "Widget.sln"
            solution.touch()
            (directory / "protocol.xml").write_text(
                '<Protocol xmlns="urn:protocol"><Name>Widget</Name><Version>2.0.0.7</Version></Protocol>',
                encoding="utf-8",
            )

            for mode, value, expected_exit, expected_output in (
                ("match", "Widget:2.0.0.7", 0, ["enabled=true", "version=2.0.0.7"]),
                ("mismatch", "widget:2.0.0.7", 0, []),
                ("whitespace", "Widget:2.0.0.7 ", 0, []),
                ("missing", "", 0, []),
                ("error", "", 1, []),
            ):
                with self.subTest(mode=mode):
                    output = directory / "github-output"
                    output.write_text("", encoding="utf-8")
                    environment = os.environ | {
                        "AZ_MODE": mode,
                        "AZ_VALUE": value,
                        "GITHUB_OUTPUT": str(output),
                        "SOLUTION_FILE": str(solution),
                    }
                    result = subprocess.run(
                        [POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", az_stub + script],
                        env=environment,
                        capture_output=True,
                        text=True,
                        encoding="utf-8",
                        check=False,
                    )
                    self.assertEqual(expected_exit, result.returncode, result.stderr)
                    self.assertEqual(expected_output, output.read_text(encoding="utf-8").splitlines())
                    visible_output = "\n".join(
                        line for line in result.stdout.splitlines() if not line.startswith("::add-mask::")
                    )
                    if value:
                        self.assertNotIn(value, visible_output)

    def run_gate(self, name, *, exception, version="2.0.0.7", counts=(0, 2, 3),
                 validate=True, partial_compare=False, lookup_failed=False, compare_version=None):
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            if validate:
                (directory / "validateResults.json").write_text(
                    json.dumps(dict(zip(("CriticalIssueCount", "MajorIssueCount", "MinorIssueCount"), counts))),
                    encoding="utf-8",
                )
            if compare_version is not None:
                (directory / "compareResults.json").write_text(
                    json.dumps({"Version": compare_version, "Issues": []}), encoding="utf-8",
                )
            if partial_compare:
                for name_part in ("compareResults.json", "currentValidateResults.json", "previousValidateResults.json"):
                    (directory / name_part).write_text("{", encoding="utf-8")

            script = workflow_step(name)["run"].replace("${{ github.workspace }}", directory.as_posix())
            environment = os.environ | {
                "COMPARE_EXCEPTION": str(exception).lower(),
                "COMPARE_LOOKUP_FAILED": str(lookup_failed).lower(),
                "EXEMPT_VERSION": version if exception else "",
            }
            result = subprocess.run(
                [BASH, "-e", "-o", "pipefail", "-c", script],
                env=environment,
                capture_output=True,
                text=True,
                encoding="utf-8",
                check=False,
            )
            state_name = "mcc-gate-state.json" if name.startswith("Major Change") else "validator-gate-state.json"
            state_file = directory / state_name
            self.assertTrue(state_file.is_file(), result.stderr)
            return result, json.loads(state_file.read_text(encoding="utf-8"))

    @unittest.skipUnless(BASH and JQ, "Bash and jq are required")
    def test_validator_waives_only_compare_checks(self):
        for exception, version, counts, validate, expected_exit, expected_mode in (
            (False, "2.0.0.7", (0, 2, 3), True, 1, "missing-compare"),
            (True, "2.0.0.7", (0, 2, 3), True, 0, "compare-skipped"),
            (True, "1.0.0.1", (0, 0, 1), True, 1, "compare-skipped"),
            (True, "2.0.0.7", (1, 0, 0), True, 1, "compare-skipped"),
            (True, "2.0.0.7", (0, 0, 0), False, 1, "missing-results"),
        ):
            with self.subTest(exception=exception, version=version, counts=counts, validate=validate):
                result, state = self.run_gate(
                    "Validator Quality Gate", exception=exception, version=version,
                    counts=counts, validate=validate,
                )
                self.assertEqual(expected_exit, result.returncode, result.stderr)
                self.assertEqual(expected_mode, state["mode"])
                self.assertEqual("passed" if expected_exit == 0 else "failed", state["status"])

    @unittest.skipUnless(BASH and JQ, "Bash and jq are required")
    def test_partial_compare_results_are_ignored_when_approved(self):
        result, state = self.run_gate("Validator Quality Gate", exception=True, partial_compare=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("compare-skipped", state["mode"])
        self.assertEqual("passed", state["status"])

    @unittest.skipUnless(BASH and JQ, "Bash and jq are required")
    def test_key_vault_lookup_failure_fails_an_otherwise_clean_gate(self):
        result, state = self.run_gate(
            "Validator Quality Gate", exception=False, counts=(0, 0, 0),
            lookup_failed=True, compare_version="1.0.0.1",
        )
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertEqual("initial", state["mode"])
        self.assertEqual("failed", state["status"])
        self.assertIn("Could not check the connector compare exception in Key Vault.", state["failures"])

    @unittest.skipUnless(BASH and JQ, "Bash and jq are required")
    def test_major_change_checker_skips_only_when_approved(self):
        for exception, expected_exit, expected_status in (
            (False, 1, "failed"),
            (True, 0, "skipped"),
        ):
            with self.subTest(exception=exception):
                result, state = self.run_gate("Major Change Checker Quality Gate", exception=exception)
                self.assertEqual(expected_exit, result.returncode, result.stderr)
                self.assertEqual(expected_status, state["status"])


if __name__ == "__main__":
    unittest.main()