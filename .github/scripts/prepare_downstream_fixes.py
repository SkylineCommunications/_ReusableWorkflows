#!/usr/bin/env python3
"""Create and assign linked downstream-fix issues for a reusable-workflows PR."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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
COMMAND_FORMAT = (
    f"Expected {COMMAND} on its own first line, then one '### owner/repository' "
    "heading per target, each followed by nonempty acceptance criteria "
    "(for example '- Assert the expected output.')."
)


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


def normalize_criteria(criteria: str) -> str:
    """Ignore line endings, per-line trailing whitespace, and edge blank lines."""
    lines = criteria.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return "\n".join(line.rstrip() for line in lines).strip("\n")


def parse_command(comment_body: str) -> dict[str, str]:
    lines = comment_body.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if not lines or lines[0] != COMMAND:
        raise OrchestrationError(f"The first line must be exactly {COMMAND}. {COMMAND_FORMAT}")
    if len("\n".join(lines[1:])) > MAX_CRITERIA_LENGTH:
        raise OrchestrationError(
            f"Acceptance criteria exceed the {MAX_CRITERIA_LENGTH}-character limit. "
            f"{COMMAND_FORMAT}"
        )

    sections: dict[str, list[str]] = {}
    seen_repositories: set[str] = set()
    current_repository: str | None = None
    for line in lines[1:]:
        heading = re.fullmatch(
            r"### ([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+)", line.rstrip()
        )
        if heading:
            repository = heading[1]
            if repository.casefold() in seen_repositories:
                raise OrchestrationError(
                    f"Duplicate repository heading {repository}. {COMMAND_FORMAT}"
                )
            seen_repositories.add(repository.casefold())
            current_repository = repository
            sections[repository] = []
        elif line.lstrip().startswith("#"):
            raise OrchestrationError(f"Malformed repository heading. {COMMAND_FORMAT}")
        elif current_repository is None:
            if line.strip():
                raise OrchestrationError(
                    f"Unscoped acceptance criteria are not allowed. {COMMAND_FORMAT}"
                )
        else:
            sections[current_repository].append(line)

    if not sections:
        raise OrchestrationError(f"No repository sections were provided. {COMMAND_FORMAT}")
    criteria = {
        repository: normalize_criteria("\n".join(section))
        for repository, section in sections.items()
    }
    for repository, text in criteria.items():
        if not text:
            raise OrchestrationError(
                f"Acceptance criteria for {repository} are empty. {COMMAND_FORMAT}"
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


def task_marker(source: SourcePullRequest, repository: str, criteria: str) -> str:
    marker = {
        "source": source.repository,
        "pr": source.number,
        "repo": repository,
        "criteria": hashlib.sha256(
            normalize_criteria(criteria).encode("utf-8")
        ).hexdigest(),
    }
    return f"<!-- downstream-fix-task {json.dumps(marker, separators=(',', ':'))} -->"


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
    client: GitHubClient,
    repository: str,
    source: SourcePullRequest,
    criteria: str,
) -> dict[str, Any] | None:
    marker = task_marker(source, repository, criteria)
    legacy_marker = issue_marker(source)
    normalized_criteria = normalize_criteria(criteria)
    matches: dict[int, dict[str, Any]] = {}
    page = 1
    while True:
        query = urllib.parse.urlencode(
            {
                "state": "all",
                "labels": LABEL,
                "sort": "created",
                "direction": "asc",
                "per_page": "100",
                "page": str(page),
            }
        )
        issues = client.request("GET", f"/repos/{repository}/issues?{query}")
        for issue in issues:
            if "pull_request" in issue:
                continue
            body = (issue.get("body") or "").replace("\r\n", "\n").replace("\r", "\n")
            matched = marker in body
            if (
                not matched
                and legacy_marker in body
                and "<!-- downstream-fix-task " not in body
            ):
                _, heading, remainder = body.partition("\n## Acceptance criteria\n\n")
                old_criteria, constraints, _ = remainder.partition(
                    "\n\n## Delivery constraints"
                )
                matched = bool(
                    heading
                    and constraints
                    and normalize_criteria(old_criteria) == normalized_criteria
                )
            if matched:
                matches[issue["number"]] = issue
        if len(issues) < 100:
            break
        page += 1

    if len(matches) > 1:
        raise OrchestrationError(
            "Found multiple downstream-fix issues with the same source PR and "
            f"acceptance criteria in {repository}; maintainer review is required"
        )
    return next(iter(matches.values()), None)


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
        issue = find_existing_issue(client, repository, source, criteria)
        if issue and issue["state"] == "closed":
            result.update(
                status="closed",
                issue_url=issue["html_url"],
                state_reason=issue.get("state_reason") or "unknown",
            )
            return result

        if issue is None:
            ensure_label(client, repository)
            issue = client.request(
                "POST",
                f"/repos/{repository}/issues",
                {
                    "title": f"[downstream fix] _ReusableWorkflows#{source.number}",
                    "body": (
                        f"{task_marker(source, repository, criteria)}\n"
                        f"{render_issue_body(source, criteria, target['workflows'])}"
                    ),
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
        elif result["status"] == "closed":
            lines.append(
                f"- [CLOSED] [{result['repo']}]({result['issue_url']}): "
                f"matching issue closed (state reason: {result.get('state_reason') or 'unknown'}); "
                "not reopened or reassigned"
            )
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
        criteria_by_repository = parse_command(
            args.comment_file.read_text(encoding="utf-8")
        )
        changed_workflows = {
            line.strip()
            for line in args.changed_workflows_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
        downstream_map = read_json(args.downstream_map_file)
        eligible_targets = {
            target["repo"]: target
            for target in select_targets(downstream_map, changed_workflows)
        }
        mapped_repositories = {entry["repo"] for entry in downstream_map}
        for repository in criteria_by_repository:
            if repository not in mapped_repositories:
                raise OrchestrationError(
                    f"Requested repository {repository} is not in DOWNSTREAM_MAP. "
                    f"{COMMAND_FORMAT}"
                )
            if repository not in eligible_targets:
                raise OrchestrationError(
                    f"Requested repository {repository} is unaffected by the PR's "
                    f"changed workflows/actions. {COMMAND_FORMAT}"
                )

        client = GitHubClient(os.environ.get("DOWNSTREAM_ISSUES_TOKEN", ""))
        results = [
            prepare_target(client, source, criteria, eligible_targets[repository])
            for repository, criteria in criteria_by_repository.items()
        ]
    except (OSError, json.JSONDecodeError, OrchestrationError) as error:
        results = [{"repo": "orchestration", "status": "failed", "error": str(error)}]

    args.result_file.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    args.summary_file.write_text(render_summary(source, results), encoding="utf-8")
    return 1 if any("error" in result for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())