import json
import sys
import tempfile
import unittest
import urllib.parse
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import yaml


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import prepare_downstream_fixes as orchestrator  # noqa: E402
from prepare_downstream_fixes import (  # noqa: E402
    COMMAND,
    OrchestrationError,
    SourcePullRequest,
    assign_copilot,
    is_copilot_assigned,
    issue_marker,
    parse_command,
    prepare_target,
    render_issue_body,
    render_summary,
    select_targets,
)


SHARED_REPOSITORY = "SkylineCommunications/BOOST-DailyRegression-SharedLibrary"
MATRIX_REPOSITORY = "SkylineCommunications/BOOST-DailyRegression-MasterWorkflow"
CONNECTOR_REPOSITORY = "SkylineCommunications/BOOST-DailyRegression-Connector-SDK"


class RecordingClient:
    def __init__(self):
        self.requests = []

    def request(self, method, path, payload=None, expected=(200,)):
        self.requests.append((method, path, payload, expected))
        if method == "GET":
            return {"assignees": [{"login": "Copilot"}]}
        return {}


class IssueClient:
    def __init__(self):
        self.requests = []
        self.issues = {}
        self.created = []

    def add_issue(self, repository, body, state="open", assigned=True):
        issues = self.issues.setdefault(repository, [])
        number = len(issues) + 1
        issue = {
            "number": number,
            "state": state,
            "html_url": f"https://github.com/{repository}/issues/{number}",
            "body": body,
            "assignees": [{"login": "Copilot"}] if assigned else [],
        }
        issues.append(issue)
        return issue

    def request(self, method, path, payload=None, expected=(200,)):
        self.requests.append((method, path, payload, expected))
        endpoint, _, query = path.partition("?")
        repository = "/".join(endpoint.split("/")[2:4])
        if method == "GET" and "/labels/" in endpoint:
            return {}
        if method == "GET" and endpoint.endswith("/issues"):
            parameters = urllib.parse.parse_qs(query)
            page = int(parameters.get("page", ["1"])[0])
            size = int(parameters.get("per_page", ["100"])[0])
            return self.issues.get(repository, [])[(page - 1) * size : page * size]
        if method == "POST" and endpoint.endswith("/issues"):
            issue = self.add_issue(repository, payload["body"], assigned=False)
            self.created.append((repository, issue))
            return issue
        if "/issues/" in endpoint:
            number = int(endpoint.split("/")[5])
            issue = next(
                item for item in self.issues[repository] if item["number"] == number
            )
            if method == "POST" and endpoint.endswith("/assignees"):
                issue["assignees"] = [{"login": "Copilot"}]
                return issue
            if method == "GET":
                return issue
        raise AssertionError(f"Unexpected GitHub request: {method} {path}")


class DownstreamMapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_directory = Path(__file__).resolve().parents[3] / ".github" / "workflows"
        workflow = yaml.safe_load(
            (cls.workflow_directory / "Test Downstream.yml").read_text(encoding="utf-8")
        )
        cls.downstream_map = json.loads(workflow["env"]["DOWNSTREAM_MAP"])

    def test_only_supported_repositories_are_dispatched(self):
        repositories = [entry["repo"] for entry in self.downstream_map]
        expected = {
            "SkylineCommunications/BOOST-DailyRegression-Connector-SDK",
            "SkylineCommunications/BOOST-DailyRegression-InternalNuGet",
            "SkylineCommunications/BOOST-DailyRegression-Skyline.DataMiner.Sdk",
            "SkylineCommunications/BOOST-DailyRegression-SharedLibrary",
            "SkylineCommunications/BOOST-DailyRegression-MasterWorkflow",
            "SkylineCommunications/BOOST-DailyRegression-NegativePaths",
        }
        self.assertEqual(expected, set(repositories))
        self.assertEqual(len(expected), len(repositories))

    def test_every_mapped_workflow_exists(self):
        for entry in self.downstream_map:
            for workflow in entry["workflows"]:
                with self.subTest(repository=entry["repo"], workflow=workflow):
                    self.assertTrue((self.workflow_directory / workflow).is_file())

    def test_connector_changes_cover_positive_and_negative_paths(self):
        targets = select_targets(self.downstream_map, {"Connector Master Workflow.yml"})
        self.assertEqual(
            [
                {
                    "repo": "SkylineCommunications/BOOST-DailyRegression-Connector-SDK",
                    "workflows": ["Connector Master Workflow.yml"],
                },
                {
                    "repo": "SkylineCommunications/BOOST-DailyRegression-NegativePaths",
                    "workflows": ["Connector Master Workflow.yml"],
                },
            ],
            targets,
        )

    def test_retired_pipelines_are_not_dispatched(self):
        targets = select_targets(
            self.downstream_map,
            {
                "Automation Master Workflow.yml",
                "Automation Master SDK Workflow.yml",
                "Automation Master Legacy Workflow.yml",
                "Connector Master Legacy Workflow.yml",
            },
        )
        self.assertEqual([], targets)


class PrepareDownstreamFixesTests(unittest.TestCase):
    def setUp(self):
        self.source = SourcePullRequest(
            repository="SkylineCommunications/_ReusableWorkflows",
            number=146,
            head_sha="abc123",
            url="https://github.com/SkylineCommunications/_ReusableWorkflows/pull/146",
            command_url="https://github.com/example/comment/1",
            workflow_run_url="https://github.com/example/actions/runs/2",
        )

    def test_parse_command_returns_acceptance_criteria(self):
        criteria = parse_command(
            f"{COMMAND}\n"
            f"### {SHARED_REPOSITORY}\n"
            "- Validate the output\n- Add coverage\n"
            f"### {MATRIX_REPOSITORY}\n"
            "- Assert installer contents"
        )

        self.assertEqual(
            criteria,
            {
                SHARED_REPOSITORY: "- Validate the output\n- Add coverage",
                MATRIX_REPOSITORY: "- Assert installer contents",
            },
        )

    def test_parse_command_requires_exact_first_line(self):
        with self.assertRaises(OrchestrationError):
            parse_command(f"{COMMAND} now\n- Validate")

    def test_parse_command_requires_acceptance_criteria(self):
        with self.assertRaises(OrchestrationError):
            parse_command(COMMAND)

    def test_select_targets_matches_workflow_allowlist(self):
        downstream_map = [
            {
                "repo": "SkylineCommunications/BOOST-DailyRegression-One",
                "workflows": ["One.yml", "Shared.yml"],
            },
            {
                "repo": "SkylineCommunications/BOOST-DailyRegression-Two",
                "workflows": ["Two.yml"],
            },
        ]

        targets = select_targets(downstream_map, {"Shared.yml"})

        self.assertEqual(
            targets,
            [
                {
                    "repo": "SkylineCommunications/BOOST-DailyRegression-One",
                    "workflows": ["Shared.yml"],
                }
            ],
        )

    def test_select_targets_rejects_repository_outside_allowlist_prefix(self):
        downstream_map = [{"repo": "someone/untrusted", "workflows": ["One.yml"]}]

        with self.assertRaises(OrchestrationError):
            select_targets(downstream_map, {"One.yml"})

    def test_marker_is_stable_for_source_pr(self):
        self.assertEqual(
            issue_marker(self.source),
            '<!-- downstream-fix {"source":"SkylineCommunications/_ReusableWorkflows","pr":146} -->',
        )

    def test_issue_body_contains_audit_and_delivery_constraints(self):
        body = render_issue_body(
            self.source,
            "- Consume `catalog-links`",
            ["Update Catalog Details Workflow.yml"],
        )

        self.assertIn(issue_marker(self.source), body)
        self.assertIn("[SkylineCommunications/_ReusableWorkflows#146]", body)
        self.assertIn("`abc123`", body)
        self.assertIn("- Consume `catalog-links`", body)
        self.assertIn("never push directly to the default branch", body)
        self.assertIn("Do not merge the pull request automatically", body)

    def test_assign_copilot_uses_agent_assignment_contract(self):
        client = RecordingClient()

        assigned = assign_copilot(
            client,
            "SkylineCommunications/BOOST-DailyRegression-One",
            42,
        )

        self.assertTrue(assigned)
        self.assertEqual(len(client.requests), 2)
        method, path, payload, expected = client.requests[0]
        self.assertEqual(method, "POST")
        self.assertEqual(
            path,
            "/repos/SkylineCommunications/BOOST-DailyRegression-One/issues/42/assignees",
        )
        self.assertEqual(expected, (201,))
        self.assertEqual(payload["assignees"], ["copilot-swe-agent[bot]"])
        self.assertEqual(
            payload["agent_assignment"],
            {
                "target_repo": "SkylineCommunications/BOOST-DailyRegression-One",
                "base_branch": "main",
                "custom_instructions": "",
                "custom_agent": "",
                "model": "",
            },
        )

    def test_copilot_assignment_accepts_github_normalized_login(self):
        self.assertTrue(
            is_copilot_assigned(
                {
                    "assignees": [
                        {"login": "SkylineCICD"},
                        {"login": "Copilot"},
                    ]
                }
            )
        )

    def test_summary_reports_successes_and_failures(self):
        summary = render_summary(
            self.source,
            [
                {
                    "repo": "SkylineCommunications/BOOST-DailyRegression-One",
                    "status": "created",
                    "issue_url": "https://github.com/example/issues/1",
                    "copilot": "assigned",
                },
                {
                    "repo": "SkylineCommunications/BOOST-DailyRegression-Two",
                    "status": "failed",
                    "error": "Copilot is unavailable",
                },
            ],
        )

        self.assertIn("[OK]", summary)
        self.assertIn("[FAIL]", summary)
        self.assertIn("Copilot is unavailable", summary)

    def run_command(self, command):
        client = IssueClient()
        downstream_map = [
            {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]},
            {"repo": MATRIX_REPOSITORY, "workflows": ["Master Workflow.yml"]},
            {"repo": CONNECTOR_REPOSITORY, "workflows": ["Connector Master Workflow.yml"]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command_file = root / "command.txt"
            changed_file = root / "changed.txt"
            map_file = root / "map.json"
            result_file = root / "results.json"
            summary_file = root / "summary.md"
            command_file.write_text(command, encoding="utf-8")
            changed_file.write_text("Master Workflow.yml\n", encoding="utf-8")
            map_file.write_text(json.dumps(downstream_map), encoding="utf-8")
            arguments = ["prepare_downstream_fixes.py"]
            values = {
                "source-repo": self.source.repository,
                "pr-number": self.source.number,
                "head-sha": self.source.head_sha,
                "source-pr-url": self.source.url,
                "command-url": self.source.command_url,
                "workflow-run-url": self.source.workflow_run_url,
                "comment-file": command_file,
                "changed-workflows-file": changed_file,
                "downstream-map-file": map_file,
                "result-file": result_file,
                "summary-file": summary_file,
            }
            for name, value in values.items():
                arguments.extend((f"--{name}", str(value)))
            with (
                patch.object(sys, "argv", arguments),
                patch.object(orchestrator, "GitHubClient", return_value=client) as factory,
            ):
                exit_code = orchestrator.main()
            results = json.loads(result_file.read_text(encoding="utf-8"))
            summary = summary_file.read_text(encoding="utf-8")
        return exit_code, results, summary, factory, client

    def test_command_selects_only_explicit_repository_headings(self):
        exit_code, results, _, _, client = self.run_command(
            f"{COMMAND}\n### {SHARED_REPOSITORY}\n"
            f"- Preserve behavior shared with {MATRIX_REPOSITORY}.\n"
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual([result["repo"] for result in results], [SHARED_REPOSITORY])
        self.assertEqual(results[0]["copilot"], "assigned")
        self.assertEqual([repository for repository, _ in client.created], [SHARED_REPOSITORY])

    def test_command_sends_each_repository_only_its_own_criteria(self):
        exit_code, _, _, _, client = self.run_command(
            f"{COMMAND}\n### {SHARED_REPOSITORY}\n"
            "- Preserve shared-library deduplication.\n"
            f"### {MATRIX_REPOSITORY}\n"
            "- Verify installer extraction.\n"
        )

        self.assertEqual(exit_code, 0)
        bodies = {repository: issue["body"] for repository, issue in client.created}
        self.assertEqual(set(bodies), {SHARED_REPOSITORY, MATRIX_REPOSITORY})
        self.assertIn("- Preserve shared-library deduplication.", bodies[SHARED_REPOSITORY])
        self.assertNotIn("- Verify installer extraction.", bodies[SHARED_REPOSITORY])
        self.assertIn("- Verify installer extraction.", bodies[MATRIX_REPOSITORY])
        self.assertNotIn("- Preserve shared-library deduplication.", bodies[MATRIX_REPOSITORY])

    def test_invalid_plans_fail_before_constructing_privileged_client(self):
        valid = f"### {SHARED_REPOSITORY}\n- Validate output.\n"
        invalid_bodies = [
            "- Unscoped criteria must not broadcast.",
            f"### {SHARED_REPOSITORY}",
            valid + f"### {SHARED_REPOSITORY}\n- Duplicate target.",
            f"## {SHARED_REPOSITORY}\n- Wrong heading level.",
            "- A global preamble.\n" + valid,
            valid + "### someone/untrusted\n- Outside the allowlist.",
            valid + "### SkylineCommunications/BOOST-DailyRegression-Unknown\n- Unknown target.",
            valid + f"### {CONNECTOR_REPOSITORY}\n- Unaffected target.",
        ]
        for body in invalid_bodies:
            with self.subTest(body=body):
                exit_code, results, summary, factory, client = self.run_command(
                    f"{COMMAND}\n{body}"
                )
                self.assertEqual(exit_code, 1)
                self.assertTrue(any("error" in result for result in results))
                self.assertIn("[FAIL]", summary)
                factory.assert_not_called()
                self.assertEqual(client.requests, [])

    def legacy_issue_body(self, criteria):
        return (
            f"{issue_marker(self.source)}\n"
            f"## Acceptance criteria\n\n{criteria}\n\n"
            "## Delivery constraints\n\n- Create a pull request."
        )

    def test_new_fixes_are_not_blocked_by_completed_legacy_issue(self):
        client = IssueClient()
        client.add_issue(
            SHARED_REPOSITORY,
            self.legacy_issue_body("- Earlier completed fix."),
            state="closed",
        )

        result = prepare_target(
            client,
            self.source,
            "- A different new fix.",
            {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]},
        )

        self.assertNotIn("error", result)
        self.assertEqual(result["status"], "created")
        self.assertEqual(len(client.created), 1)
        self.assertIn("- A different new fix.", client.created[0][1]["body"])

    def test_distinct_criteria_and_source_updates_preserve_retry_identity(self):
        client = IssueClient()
        target = {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]}
        first = prepare_target(client, self.source, "- First fix.", target)
        second = prepare_target(
            client, self.source, "- Second fix.\n- Preserve existing checks.", target
        )
        client.requests.clear()
        moved_source = replace(
            self.source,
            head_sha="def456",
            command_url="https://github.com/example/comment/3",
        )
        retry = prepare_target(
            client,
            moved_source,
            "- Second fix. \r\n- Preserve existing checks.\r\n",
            target,
        )

        for result in (first, second, retry):
            self.assertNotIn("error", result)
        self.assertEqual(first["status"], "created")
        self.assertEqual(second["status"], "created")
        self.assertEqual(retry["status"], "reused")
        self.assertEqual(second["issue_url"], retry["issue_url"])
        self.assertEqual(len(client.created), 2)
        self.assertFalse(any(path.endswith("/assignees") for _, path, _, _ in client.requests))

    def test_identical_closed_task_is_reported_without_restarting_it(self):
        client = IssueClient()
        target = {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]}
        original = prepare_target(client, self.source, "- Assert output.", target)
        client.issues[SHARED_REPOSITORY][0]["state"] = "closed"
        client.requests.clear()

        repeated = prepare_target(client, self.source, "- Assert output.", target)

        self.assertNotIn("error", repeated)
        self.assertEqual(repeated["status"], "closed")
        self.assertEqual(original["issue_url"], repeated["issue_url"])
        self.assertEqual(len(client.created), 1)
        self.assertTrue(all(method == "GET" for method, _, _, _ in client.requests))
        self.assertIn("closed", render_summary(self.source, [repeated]))

    def test_identical_legacy_tasks_are_recognized_without_modification(self):
        for state, expected_status in (("open", "reused"), ("closed", "closed")):
            with self.subTest(state=state):
                client = IssueClient()
                old_issue = client.add_issue(
                    SHARED_REPOSITORY,
                    self.legacy_issue_body("- Assert output."),
                    state=state,
                )
                result = prepare_target(
                    client,
                    self.source,
                    "- Assert output.",
                    {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]},
                )

                self.assertNotIn("error", result)
                self.assertEqual(result["status"], expected_status)
                self.assertEqual(result["issue_url"], old_issue["html_url"])
                self.assertEqual(client.created, [])
                self.assertTrue(all(method == "GET" for method, _, _, _ in client.requests))

    def test_task_lookup_checks_history_after_first_page(self):
        client = IssueClient()
        for _ in range(100):
            client.add_issue(SHARED_REPOSITORY, "An unrelated historical task.")
        expected = client.add_issue(
            SHARED_REPOSITORY, self.legacy_issue_body("- Assert output.")
        )

        result = prepare_target(
            client,
            self.source,
            "- Assert output.",
            {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]},
        )

        self.assertNotIn("error", result)
        self.assertEqual(result["status"], "reused")
        self.assertEqual(result["issue_url"], expected["html_url"])
        self.assertEqual(client.created, [])

    def test_duplicate_matching_tasks_on_different_pages_fail_without_writes(self):
        client = IssueClient()
        body = self.legacy_issue_body("- Assert output.")
        client.add_issue(SHARED_REPOSITORY, body)
        for _ in range(99):
            client.add_issue(SHARED_REPOSITORY, "An unrelated historical task.")
        client.add_issue(SHARED_REPOSITORY, body, state="closed")

        result = prepare_target(
            client,
            self.source,
            "- Assert output.",
            {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]},
        )

        self.assertIn("error", result)
        self.assertEqual(client.created, [])
        self.assertTrue(all(method == "GET" for method, _, _, _ in client.requests))

    def test_retry_finishes_assignment_for_an_existing_unassigned_task(self):
        client = IssueClient()
        issue = client.add_issue(
            SHARED_REPOSITORY,
            self.legacy_issue_body("- Assert output."),
            assigned=False,
        )

        result = prepare_target(
            client,
            self.source,
            "- Assert output.",
            {"repo": SHARED_REPOSITORY, "workflows": ["Master Workflow.yml"]},
        )

        self.assertNotIn("error", result)
        self.assertEqual(result["status"], "reused")
        self.assertEqual(result["copilot"], "assigned")
        self.assertEqual(result["issue_url"], issue["html_url"])
        self.assertEqual(client.created, [])
        self.assertEqual(
            [path for method, path, _, _ in client.requests if method == "POST"],
            [f"/repos/{SHARED_REPOSITORY}/issues/{issue['number']}/assignees"],
        )


if __name__ == "__main__":
    unittest.main()