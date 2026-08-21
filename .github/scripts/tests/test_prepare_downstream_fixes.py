import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from prepare_downstream_fixes import (  # noqa: E402
    COMMAND,
    OrchestrationError,
    SourcePullRequest,
    assign_copilot,
    is_copilot_assigned,
    issue_marker,
    parse_command,
    render_issue_body,
    render_summary,
    select_targets,
)


class RecordingClient:
    def __init__(self):
        self.requests = []

    def request(self, method, path, payload=None, expected=(200,)):
        self.requests.append((method, path, payload, expected))
        if method == "GET":
            return {"assignees": [{"login": "Copilot"}]}
        return {}


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
        criteria = parse_command(f"{COMMAND}\n- Validate the output\n- Add coverage")

        self.assertEqual(criteria, "- Validate the output\n- Add coverage")

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


if __name__ == "__main__":
    unittest.main()