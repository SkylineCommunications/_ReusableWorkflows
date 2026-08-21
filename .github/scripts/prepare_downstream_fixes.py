#!/usr/bin/env python3
"""Create and assign linked downstream-fix issues for a reusable-workflows PR."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


COMMAND = "/prepare-downstream-fixes"
ASSIGNEE = "copilot-swe-agent[bot]"
COPILOT_ASSIGNEE_LOGINS = {"copilot", "copilot-swe-agent", ASSIGNEE.casefold()}
LABEL = "downstream-fix"
MAX_CRITERIA_LENGTH = 16_384


class OrchestrationError(RuntimeError):
    """Raised when the requested operation cannot be completed safely."""


@dataclass(frozen=True)
class SourcePullRequest:
    repository: str
    number: int
    head_sha: str
    url: str
    command_url: str
    workflow_run_url: str


class GitHubClient:
    def __init__(self, token: str, api_url: str = "https://api.github.com") -> None:
        if not token:
            raise OrchestrationError("DOWNSTREAM_ISSUES_TOKEN is not configured")
        self._token = token
        self._api_url = api_url.rstrip("/")

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        expected: tuple[int, ...] = (200,),
    ) -> Any:
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(
            f"{self._api_url}{path}",
            data=data,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "User-Agent": "reusable-workflows-downstream-fix-orchestrator",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request) as response:
                status = response.status
                body = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise OrchestrationError(
                f"GitHub API {method} {path} failed with {error.code}: {detail}"
            ) from error

        if status not in expected:
            raise OrchestrationError(
                f"GitHub API {method} {path} returned unexpected status {status}"
            )
        return json.loads(body) if body else None


def parse_command(comment_body: str) -> str:
    lines = comment_body.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != COMMAND:
        raise OrchestrationError(f"The first line must be exactly {COMMAND}")
    criteria = "\n".join(lines[1:]).strip()
    if not criteria:
        raise OrchestrationError("Add acceptance criteria below the command")
    if len(criteria) > MAX_CRITERIA_LENGTH:
        raise OrchestrationError(
            f"Acceptance criteria exceed the {MAX_CRITERIA_LENGTH}-character limit"
        )
    return criteria


def select_targets(
    downstream_map: list[dict[str, Any]], changed_workflows: set[str]
) -> list[dict[str, Any]]:
    targets: list[dict[str, Any]] = []
    seen_repositories: set[str] = set()
    for entry in downstream_map:
        repository = entry.get("repo")
        workflows = entry.get("workflows")
        if (
            not isinstance(repository, str)
            or not repository.startswith("SkylineCommunications/BOOST-DailyRegression-")
            or not isinstance(workflows, list)
            or not all(isinstance(workflow, str) for workflow in workflows)
        ):
            raise OrchestrationError("DOWNSTREAM_MAP contains an invalid allowlist entry")
        if repository in seen_repositories:
            raise OrchestrationError(f"DOWNSTREAM_MAP contains duplicate repo {repository}")
        seen_repositories.add(repository)
        matched = sorted(changed_workflows.intersection(workflows))
        if matched:
            targets.append({"repo": repository, "workflows": matched})
    return targets


def issue_marker(source: SourcePullRequest) -> str:
    marker = {"source": source.repository, "pr": source.number}
    return f"<!-- downstream-fix {json.dumps(marker, separators=(',', ':'))} -->"


def render_issue_body(
    source: SourcePullRequest, criteria: str, workflows: list[str]
) -> str:
    workflow_list = "\n".join(f"- `{workflow}`" for workflow in workflows)
    return f"""{issue_marker(source)}
# Downstream coverage for {source.repository}#{source.number}

Update this repository's downstream battery coverage for [{source.repository}#{source.number}]({source.url}).

## Authorized request

- Source head: `{source.head_sha}`
- Command: {source.command_url}
- Orchestration run: {source.workflow_run_url}
- Affected reusable workflows:
{workflow_list}

## Acceptance criteria

{criteria}

## Delivery constraints

- Create a pull request for the changes; never push directly to the default branch.
- Do not merge the pull request automatically.
- Keep final reusable-workflow references on their normal production ref. Do not commit temporary `test-pr-*` or `test-downstream` refs.
- Follow this repository's receiver, fixture, and verification conventions.
- Link the downstream pull request back to {source.url}.
"""


def ensure_label(client: GitHubClient, repository: str) -> None:
    encoded_label = urllib.parse.quote(LABEL, safe="")
    try:
        client.request("GET", f"/repos/{repository}/labels/{encoded_label}")
    except OrchestrationError as error:
        if " failed with 404:" not in str(error):
            raise
        client.request(
            "POST",
            f"/repos/{repository}/labels",
            {"name": LABEL, "color": "1d76db", "description": "Linked downstream fix"},
            expected=(201,),
        )


def find_existing_issue(
    client: GitHubClient, repository: str, marker: str
) -> dict[str, Any] | None:
    query = urllib.parse.urlencode(
        {"state": "all", "labels": LABEL, "per_page": "100"}
    )
    issues = client.request("GET", f"/repos/{repository}/issues?{query}")
    matches = [
        issue
        for issue in issues
        if "pull_request" not in issue and marker in (issue.get("body") or "")
    ]
    if len(matches) > 1:
        raise OrchestrationError(
            f"Found multiple downstream-fix issues for the source PR in {repository}"
        )
    return matches[0] if matches else None


def assign_copilot(
    client: GitHubClient, repository: str, issue_number: int
) -> bool:
    client.request(
        "POST",
        f"/repos/{repository}/issues/{issue_number}/assignees",
        {
            "assignees": [ASSIGNEE],
            "agent_assignment": {
                "target_repo": repository,
                "base_branch": "main",
                "custom_instructions": "",
                "custom_agent": "",
                "model": "",
            },
        },
        expected=(201,),
    )
    issue = client.request("GET", f"/repos/{repository}/issues/{issue_number}")
    return is_copilot_assigned(issue)


def is_copilot_assigned(issue: dict[str, Any]) -> bool:
    assignees = {
        assignee["login"].casefold()
        for assignee in issue.get("assignees", [])
        if isinstance(assignee.get("login"), str)
    }
    return not assignees.isdisjoint(COPILOT_ASSIGNEE_LOGINS)


def prepare_target(
    client: GitHubClient,
    source: SourcePullRequest,
    criteria: str,
    target: dict[str, Any],
) -> dict[str, Any]:
    repository = target["repo"]
    result: dict[str, Any] = {"repo": repository, "status": "failed"}
    try:
        ensure_label(client, repository)
        marker = issue_marker(source)
        issue = find_existing_issue(client, repository, marker)
        if issue and issue["state"] != "open":
            raise OrchestrationError(
                f"Existing issue {issue['html_url']} is closed; maintainer review is required"
            )

        if issue is None:
            issue = client.request(
                "POST",
                f"/repos/{repository}/issues",
                {
                    "title": f"[downstream fix] _ReusableWorkflows#{source.number}",
                    "body": render_issue_body(source, criteria, target["workflows"]),
                    "labels": [LABEL],
                },
                expected=(201,),
            )
            result["status"] = "created"
        else:
            result["status"] = "reused"

        result["issue_url"] = issue["html_url"]
        if is_copilot_assigned(issue):
            result["copilot"] = "already-assigned"
        elif assign_copilot(client, repository, issue["number"]):
            result["copilot"] = "assigned"
        else:
            raise OrchestrationError("Copilot assignment could not be verified")
    except OrchestrationError as error:
        result["error"] = str(error)
    return result


def render_summary(source: SourcePullRequest, results: list[dict[str, Any]]) -> str:
    lines = [
        "<!-- downstream-fixes-summary -->",
        f"**Downstream fix preparation for `{source.head_sha}`**",
        "",
    ]
    for result in results:
        if "error" in result:
            lines.append(f"- [FAIL] `{result['repo']}`: {result['error']}")
        else:
            lines.append(
                f"- [OK] [{result['repo']}]({result['issue_url']}): "
                f"issue {result['status']}; Copilot {result['copilot']}"
            )
    lines.extend(
        [
            "",
            "Each Copilot assignment runs independently in its downstream repository. "
            "Review and merge the resulting pull requests separately.",
        ]
    )
    return "\n".join(lines) + "\n"


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", required=True)
    parser.add_argument("--pr-number", type=int, required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--source-pr-url", required=True)
    parser.add_argument("--command-url", required=True)
    parser.add_argument("--workflow-run-url", required=True)
    parser.add_argument("--comment-file", type=Path, required=True)
    parser.add_argument("--changed-workflows-file", type=Path, required=True)
    parser.add_argument("--downstream-map-file", type=Path, required=True)
    parser.add_argument("--result-file", type=Path, required=True)
    parser.add_argument("--summary-file", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    source = SourcePullRequest(
        repository=args.source_repo,
        number=args.pr_number,
        head_sha=args.head_sha,
        url=args.source_pr_url,
        command_url=args.command_url,
        workflow_run_url=args.workflow_run_url,
    )

    results: list[dict[str, Any]] = []
    try:
        criteria = parse_command(args.comment_file.read_text(encoding="utf-8"))
        changed_workflows = {
            line.strip()
            for line in args.changed_workflows_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
        targets = select_targets(read_json(args.downstream_map_file), changed_workflows)
        if not targets:
            raise OrchestrationError("No mapped downstream repositories are affected")

        client = GitHubClient(os.environ.get("DOWNSTREAM_ISSUES_TOKEN", ""))
        results = [prepare_target(client, source, criteria, target) for target in targets]
    except (OSError, json.JSONDecodeError, OrchestrationError) as error:
        results = [{"repo": "orchestration", "status": "failed", "error": str(error)}]

    args.result_file.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    args.summary_file.write_text(render_summary(source, results), encoding="utf-8")
    return 1 if any("error" in result for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())