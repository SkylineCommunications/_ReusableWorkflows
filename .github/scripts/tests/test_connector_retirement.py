import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


WORKFLOWS = Path(__file__).resolve().parents[3] / ".github" / "workflows"
WORKFLOW = WORKFLOWS / "Connector Master Workflow.yml"
RETIRED_WORKFLOWS = (
    "Connector Master SDK Workflow.yml",
    "Connector Master Legacy Workflow.yml",
    "Automation Master Workflow.yml",
    "Automation Master SDK Workflow.yml",
    "Automation Master Legacy Workflow.yml",
)
ACTION_PREFIX = "SkylineCommunications/_ReusableWorkflows/.github/actions/"
SDK_JOBS = {
    "validate_skyline_quality_gate": "SDK Skyline Quality Gate",
    "auto_generate_catalog_yaml": "Auto-Generating Catalog from GitHub",
    "artifact_creation": "Artifact Creation",
    "artifact_registration": "Artifact Registration and Upload",
}
BASH = shutil.which("bash") or next(
    (str(path) for path in (Path("C:/Program Files/Git/bin/bash.exe"),) if path.is_file()),
    None,
)


def workflow_steps(steps):
    """Visit action/run steps, including the existing parallel step groups."""
    for step in steps:
        if "parallel" in step:
            yield from workflow_steps(step["parallel"])
        else:
            yield step


def job_needs(job):
    needs = job.get("needs", [])
    return [needs] if isinstance(needs, str) else needs


def uses_action(step, action):
    return step.get("uses", "").split("@", 1)[0] == ACTION_PREFIX + action


class ConnectorRetirementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.text)
        # PyYAML's YAML 1.1 resolver reads the unquoted Actions key "on" as True.
        cls.events = cls.workflow.get("on", cls.workflow.get(True))
        cls.call = cls.events["workflow_call"]
        cls.jobs = cls.workflow["jobs"]

    def steps(self, job_id):
        return list(workflow_steps(self.jobs[job_id]["steps"]))

    def step(self, job_id, name):
        return next(step for step in self.steps(job_id) if step.get("name") == name)

    def test_retired_entrypoints_are_deleted_not_redirected(self):
        for filename in RETIRED_WORKFLOWS:
            with self.subTest(filename=filename):
                self.assertFalse((WORKFLOWS / filename).exists())
                self.assertNotIn(filename, self.text)

    def test_sdk_jobs_are_inline_with_existing_display_names(self):
        expected_names = {
            "validate_trigger": "Validate Trigger",
            "check_deprecated_item": "Check deprecated items",
            "check_oidc": "Check OIDC",
            **SDK_JOBS,
            "set_repo_type": "Set Repo Type",
        }
        self.assertEqual(expected_names, {key: job["name"] for key, job in self.jobs.items()})
        for job in self.jobs.values():
            self.assertNotIn("uses", job)
            self.assertIn("steps", job)
            self.assertIn("runs-on", job)
        for obsolete in ("CI_SDK", "CI_Legacy", "check_solution_type", "SDKChecker", "isSdk"):
            self.assertNotIn(obsolete, self.text)

    def test_internal_actions_follow_main_ref_convention(self):
        for job_id in self.jobs:
            for step in self.steps(job_id):
                reference = step.get("uses", "")
                if reference.startswith(ACTION_PREFIX):
                    with self.subTest(job=job_id, action=reference):
                        self.assertTrue(reference.endswith("@main"))

    def test_public_call_interface_is_unchanged(self):
        self.assertEqual({"workflow_call"}, set(self.events))
        expected_types = {
            "referenceName": "string",
            "runNumber": "string",
            "referenceType": "string",
            "repository": "string",
            "owner": "string",
            "oidc-client-id": "string",
            "oidc-tenant-id": "string",
            "oidc-subscription-id": "string",
            "sonarCloudProjectName": "string",
            "debug": "boolean",
            "solution-filter-name": "string",
        }
        self.assertEqual(expected_types, {
            name: definition["type"] for name, definition in self.call["inputs"].items()
        })
        for definition in self.call["inputs"].values():
            self.assertIs(definition["required"], False)
            self.assertNotIn("default", definition)
        self.assertEqual({
            "api-key": {"required": False},
            "sonarCloudToken": {"required": False},
            "azureToken": {"required": False},
        }, self.call["secrets"])

    def test_quality_gate_output_points_to_the_inline_sdk_job(self):
        self.assertEqual({
            "quality_gate": {
                "description": "Results from Skyline Quality Gate.",
                "value": "${{ jobs.validate_skyline_quality_gate.outputs.quality }}",
            },
        }, self.call["outputs"])
        self.assertEqual(
            {"quality": "${{ steps.quality-step.outputs.results }}"},
            self.jobs["validate_skyline_quality_gate"]["outputs"],
        )
        summary = self.step("validate_skyline_quality_gate", "Quality Gate")
        self.assertEqual("quality-step", summary["id"])
        self.assertEqual("always()", summary["if"])
        self.assertTrue(uses_action(summary, "quality-gate-summary"))
        for input_name, step_id in (
            ("unit-tests-outcome", "unit-tests"),
            ("validator-outcome", "validator-quality-gate"),
            ("major-change-checker-outcome", "mcc-quality-gate"),
        ):
            self.assertEqual("${{ steps." + step_id + ".outcome }}", summary["with"][input_name])
        self.assertIn("steps.sonarcloud-quality-gate-check.outcome", summary["with"]["sonar-outcome"])

    def test_guard_failure_gates_every_job(self):
        guard = self.jobs["validate_trigger"]
        self.assertEqual([], job_needs(guard))
        self.assertNotIn("if", guard)
        self.assertFalse(guard.get("continue-on-error", False))
        self.assertTrue(uses_action(guard["steps"][0], "guard-trigger"))
        self.assertNotIn("if", guard["steps"][0])
        self.assertFalse(guard["steps"][0].get("continue-on-error", False))

        def ancestors(job_id, visiting=()):
            self.assertNotIn(job_id, visiting, "Cyclic job dependencies")
            result = set()
            for dependency in job_needs(self.jobs[job_id]):
                self.assertIn(dependency, self.jobs)
                result.add(dependency)
                result.update(ancestors(dependency, visiting + (job_id,)))
            return result

        for job_id, job in self.jobs.items():
            with self.subTest(job=job_id):
                if job_id != "validate_trigger":
                    self.assertIn("validate_trigger", ancestors(job_id))
                # These job-level status functions can bypass failed/skipped needs.
                self.assertNotRegex(str(job.get("if", "")), r"\b(always|failure|cancelled)\s*\(")

    def test_every_needs_expression_has_a_direct_dependency(self):
        for job_id, job in self.jobs.items():
            with self.subTest(job=job_id):
                referenced = set(re.findall(r"\bneeds\.([A-Za-z0-9_-]+)\.", yaml.safe_dump(job)))
                self.assertLessEqual(referenced, set(job_needs(job)))
                self.assertLessEqual(set(job_needs(job)), set(self.jobs))

    def test_oidc_is_resolved_once_with_overrides_and_fork_detection(self):
        resolvers = [
            (job_id, step) for job_id in self.jobs for step in self.steps(job_id)
            if uses_action(step, "resolve-oidc")
        ]
        self.assertEqual(1, len(resolvers))
        job_id, resolver = resolvers[0]
        self.assertEqual("check_oidc", job_id)
        self.assertEqual({
            "client-id": "${{ inputs.oidc-client-id }}",
            "tenant-id": "${{ inputs.oidc-tenant-id }}",
            "subscription-id": "${{ inputs.oidc-subscription-id }}",
            "repository-owner": "${{ github.repository_owner }}",
            "is-fork": "${{ steps.detect-fork.outputs.is-fork }}",
        }, resolver["with"])
        for output in ("client-id", "tenant-id", "subscription-id", "use-oidc", "is-skyline-managed"):
            self.assertEqual(
                "${{ steps.resolve.outputs." + output + " }}",
                self.jobs["check_oidc"]["outputs"][output],
            )
        self.assertEqual(
            "${{ steps.detect-fork.outputs.is-fork }}",
            self.jobs["check_oidc"]["outputs"]["is-fork"],
        )
        fork = self.step("check_oidc", "Detect forked pull request")
        self.assertEqual({
            "EVENT_NAME": "${{ github.event_name }}",
            "HEAD_REPOSITORY": "${{ github.event.pull_request.head.repo.full_name }}",
            "REPOSITORY": "${{ github.repository }}",
        }, fork["env"])

    def test_resolved_oidc_reaches_all_sdk_and_repo_type_jobs(self):
        self.assertNotIn("inputs.use-oidc", self.text)
        for job_id in (*SDK_JOBS, "set_repo_type"):
            with self.subTest(job=job_id):
                self.assertIn("check_oidc", job_needs(self.jobs[job_id]))
                login = self.step(job_id, "Azure Login")
                self.assertEqual({
                    key: "${{ needs.check_oidc.outputs." + key + " }}"
                    for key in ("client-id", "tenant-id", "subscription-id")
                }, login["with"])
                if job_id in SDK_JOBS:
                    self.assertEqual("needs.check_oidc.outputs.use-oidc == 'true'", login["if"])
                loaders = [step for step in self.steps(job_id) if uses_action(step, "load-secrets")]
                self.assertTrue(loaders)
                for loader in loaders:
                    self.assertEqual(
                        "${{ needs.check_oidc.outputs.use-oidc }}", loader["with"]["use-oidc"],
                    )
                self.assertNotIn("inputs.oidc-", yaml.safe_dump(self.jobs[job_id]))

        for job_id, name in (
            ("validate_skyline_quality_gate", "Check connector compare exception"),
            ("auto_generate_catalog_yaml", "Retrieve reusable workflows token from Key Vault"),
            ("artifact_registration", "Install Tools"),
            ("artifact_registration", "Sign generated dmprotocol package"),
            ("artifact_registration", "Find published Catalog ID"),
            ("artifact_registration", "Load DataMiner Dependabot signing secret"),
            ("artifact_registration", "Notify DataMiner Dependabot"),
            ("artifact_registration", "Connector Administration"),
        ):
            with self.subTest(job=job_id, step=name):
                self.assertIn("needs.check_oidc.outputs.use-oidc == 'true'", self.step(job_id, name)["if"])

    def test_credential_compatibility_mappings_are_preserved(self):
        azure_override = "AZURE_TOKEN=${{ secrets.azureToken }}"
        expected_overrides = {
            "validate_skyline_quality_gate": [
                azure_override, "SONAR_TOKEN=${{ secrets.sonarCloudToken }}",
                "DATAMINER_TOKEN=${{ secrets.api-key }}",
            ],
            "auto_generate_catalog_yaml": [azure_override],
            "artifact_creation": [azure_override],
            "artifact_registration": ["DATAMINER_TOKEN=${{ secrets.api-key }}"],
        }
        for job_id, overrides in expected_overrides.items():
            with self.subTest(job=job_id):
                self.assertEqual(overrides, self.step(job_id, "Load secrets")["with"]["overrides"].splitlines())
        for job_id in ("validate_skyline_quality_gate", "auto_generate_catalog_yaml", "artifact_creation"):
            self.assertEqual({
                "repository-owner": "${{ github.repository_owner }}",
                "github-token": "${{ secrets.GITHUB_TOKEN }}",
                "azure-token": "${{ env.AZURE_TOKEN }}",
            }, self.step(job_id, "Setup NuGet sources")["with"])
        self.assertEqual(
            "${{ env.SONAR_TOKEN }}",
            self.step("validate_skyline_quality_gate", "Get SonarCloud Status")["with"]["token"],
        )
        self.assertEqual(
            "${{ env.SKYLINECOMMUNICATIONS_GITHUB_TOKEN }}",
            self.step("artifact_registration", "Setup Skyline NuGet sources")["with"]
            ["skylinecommunications-github-token"],
        )

    def test_repo_type_write_is_default_branch_managed_oidc_only(self):
        job = self.jobs["set_repo_type"]
        for condition in (
            "github.ref_type == 'branch'",
            "github.ref_name == github.event.repository.default_branch",
            "github.event_name != 'pull_request'",
            "needs.check_oidc.outputs.is-skyline-managed == 'true'",
            "needs.check_oidc.outputs.is-fork != 'true'",
            "needs.check_oidc.outputs.use-oidc == 'true'",
        ):
            self.assertIn(condition, job["if"])
        self.assertEqual({
            "repo-types": "Connector",
            "token": "${{ env.REUSABLE_WORKFLOWS_TOKEN }}",
        }, self.step("set_repo_type", "Set repo type")["with"])
        self.assertEqual(
            ["reusable-workflows-token"],
            self.step("set_repo_type", "Load secrets")["with"]["secret-names"].splitlines(),
        )

    def test_job_permissions_remain_least_privilege(self):
        read = {"contents": "read"}
        oidc_read = read | {"id-token": "write", "packages": "read"}
        expected = {
            "validate_trigger": read,
            "check_deprecated_item": read,
            "check_oidc": read,
            "validate_skyline_quality_gate": oidc_read | {"pull-requests": "write"},
            "auto_generate_catalog_yaml": oidc_read | {"contents": "write"},
            "artifact_creation": oidc_read,
            "artifact_registration": oidc_read,
            "set_repo_type": read | {"id-token": "write"},
        }
        self.assertNotIn("permissions", self.workflow)
        self.assertEqual(expected, {key: job["permissions"] for key, job in self.jobs.items()})

    def test_publication_dependencies_and_artifact_names_are_preserved(self):
        registration = self.jobs["artifact_registration"]
        self.assertEqual("github.ref_type == 'tag'", registration["if"])
        self.assertLessEqual(
            {"validate_skyline_quality_gate", "artifact_creation"},
            set(job_needs(registration)),
        )
        self.assertNotIn("auto_generate_catalog_yaml", job_needs(registration))
        catalog_if = self.jobs["auto_generate_catalog_yaml"]["if"]
        self.assertIn("github.ref_type == 'branch'", catalog_if)
        self.assertIn("github.event_name != 'pull_request'", catalog_if)
        for job_id, expected in {
            "validate_skyline_quality_gate": ["sonar-report-task", "validatorResults", "SBOM"],
            "auto_generate_catalog_yaml": ["Catalog Details"],
            "artifact_creation": ["Connector Package"],
            "artifact_registration": ["Catalog Details"],
        }.items():
            uploaded = [
                step["with"]["name"] for step in self.steps(job_id)
                if step.get("uses", "").startswith("actions/upload-artifact@")
            ]
            self.assertEqual(expected, uploaded, job_id)
        downloaded = [
            step["with"]["name"] for step in self.steps("artifact_registration")
            if step.get("uses", "").startswith("actions/download-artifact@")
        ]
        self.assertEqual(["Connector Package", "SBOM"], downloaded)
        for name in ("Create DMProtocol - Release", "Create DMProtocol - Build", "Find and extract Protocol Version"):
            self.assertIn(
                "steps.findSlnFile.outputs.solutionDirPath", self.step("artifact_creation", name)["run"],
            )

    def test_explicit_shells_and_env_based_new_scripts(self):
        for job_id in self.jobs:
            for step in self.steps(job_id):
                if "run" in step:
                    self.assertIn("shell", step, (job_id, step.get("name")))
        for job_id, name in (
            ("check_deprecated_item", "Check if obsolete inputs are still used"),
            ("check_deprecated_item", "Check if obsolete secrets are still used"),
            ("check_oidc", "Detect forked pull request"),
            ("validate_skyline_quality_gate", "Find solution file"),
            ("artifact_creation", "Find solution file"),
        ):
            step = self.step(job_id, name)
            self.assertEqual("bash", step["shell"])
            self.assertIn("env", step)
            self.assertNotIn("${{", step["run"])
        warnings = self.step("check_deprecated_item", "Check if obsolete inputs are still used")
        self.assertEqual({
            "${{ inputs." + name + " }}"
            for name in ("referenceName", "runNumber", "referenceType", "repository", "owner")
        }, set(warnings["env"].values()))
        self.assertIn("can be safely removed", warnings["run"])
        secrets = self.step("check_deprecated_item", "Check if obsolete secrets are still used")
        self.assertEqual("github.repository_owner == 'SkylineCommunications'", secrets["if"])
        self.assertEqual({
            "AZURE_TOKEN": "${{ secrets.azureToken }}",
            "SONAR_TOKEN": "${{ secrets.sonarCloudToken }}",
        }, secrets["env"])

    def run_bash(self, script, directory, environment):
        output = directory / "github-output"
        output.write_text("", encoding="utf-8")
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", "-e", "-o", "pipefail"],
            input=script,
            cwd=directory,
            env=os.environ | {"GITHUB_OUTPUT": output.as_posix()} | environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
            check=False,
        )
        values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        return result, values

    @unittest.skipUnless(BASH, "Bash is required")
    def test_solution_discovery_success_and_fail_closed_cases(self):
        cases = (
            ((), "", None, "No solution file found"),
            (("Connector.slnf",), "Connector.slnf", None, ".slnf filters are not supported"),
            (("Connector.sln",), "", "./Connector.sln", None),
            (("src with spaces/Connector.slnx",), "", "./src with spaces/Connector.slnx", None),
            (("One.sln", "Two.slnx"), "", None, "Multiple solution files found"),
            (("One.sln", "Two.slnx"), "Missing.sln", None, "No solution file found"),
            (("One.sln", "src/Two.slnx"), "Two.slnx", "./src/Two.slnx", None),
            (("src/Connector.sln", "other/Connector.sln"), "Connector.sln", None,
             "Multiple solution files found"),
        )
        for job_id in ("validate_skyline_quality_gate", "artifact_creation"):
            discovery = self.step(job_id, "Find solution file")
            self.assertEqual(
                {"SOLUTION_FILTER_NAME": "${{ inputs.solution-filter-name }}"}, discovery["env"],
            )
            for filenames, filter_name, expected_path, error in cases:
                with self.subTest(job=job_id, files=filenames, filter=filter_name):
                    with tempfile.TemporaryDirectory(prefix="connector cutover ") as temporary_directory:
                        directory = Path(temporary_directory)
                        for filename in filenames:
                            path = directory / filename
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.touch()
                        result, values = self.run_bash(
                            discovery["run"], directory, {"SOLUTION_FILTER_NAME": filter_name},
                        )
                        if error:
                            self.assertEqual(1, result.returncode, result.stderr)
                            self.assertIn(error, result.stdout)
                            self.assertEqual({}, values)
                            if error.startswith("Multiple"):
                                self.assertIn("solution-filter-name", result.stdout)
                        else:
                            self.assertEqual(0, result.returncode, result.stderr)
                            self.assertEqual(expected_path, values["solutionFilePath"])
                            if job_id == "artifact_creation":
                                self.assertEqual(expected_path.rsplit("/", 1)[0], values["solutionDirPath"])

    @unittest.skipUnless(BASH, "Bash is required")
    def test_fork_detection_preserves_master_behavior(self):
        script = self.step("check_oidc", "Detect forked pull request")["run"]
        for event, head, expected in (
            ("pull_request", "SkylineCommunications/Connector", "false"),
            ("pull_request", "contributor/Connector", "true"),
            ("pull_request", "", "true"),
            ("push", "", "false"),
            ("workflow_dispatch", "", "false"),
        ):
            with self.subTest(event=event, head=head):
                with tempfile.TemporaryDirectory(prefix="connector cutover ") as temporary_directory:
                    result, values = self.run_bash(script, Path(temporary_directory), {
                        "EVENT_NAME": event,
                        "HEAD_REPOSITORY": head,
                        "REPOSITORY": "SkylineCommunications/Connector",
                    })
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual({"is-fork": expected}, values)


if __name__ == "__main__":
    unittest.main()
