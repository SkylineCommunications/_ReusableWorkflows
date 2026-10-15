"""Authorize and tag an internal NuGet prerelease from a fork PR comment."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-internal\.(0|[1-9][0-9]*)"
)
COMMAND = re.compile(r"/create-prerelease ([^\s]+)")


def parse_command(body: str) -> str:
    match = COMMAND.fullmatch(body)
    if match is None or VERSION.fullmatch(match.group(1)) is None:
        raise ValueError("Expected /create-prerelease <major.minor.patch-internal.number> on one line")
    return match.group(1)


class GitHubAPI:
    def __init__(self, token: str):
        self.token = token

    def request(self, method: str, path: str, data: dict | None = None) -> dict:
        request = Request(
            f"https://api.github.com{path}",
            data=None if data is None else json.dumps(data).encode("utf-8"),
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else {}
        except HTTPError as error:
            if error.code == 404:
                raise LookupError(f"GitHub returned 404 for {method} {path}") from error
            if error.code == 403:
                response = json.loads(error.read())
                raise PermissionError(f"GitHub denied {method} {path}: {response.get('message', 'Forbidden')}") from error
            if error.code == 422:
                response = json.loads(error.read())
                errors = response.get("errors", [])
                details = [item.get("message", item.get("code", "")) if isinstance(item, dict) else str(item)
                           for item in errors]
                reason = "; ".join([response.get("message", "Validation failed"), *details])
                raise RuntimeError(f"GitHub returned 422 for {method} {path}: {reason}") from error
            raise RuntimeError(f"GitHub returned {error.code} for {method} {path}") from error

    def get(self, path: str) -> dict:
        return self.request("GET", path)

    def post(self, path: str, data: dict) -> dict:
        return self.request("POST", path, data)

def validate_pr(api: GitHubAPI, repository: str, number: int, head: str | None = None) -> dict:
    pr = api.get(f"/repos/{repository}/pulls/{number}")
    if pr["state"] != "open" or pr["base"]["repo"]["full_name"] != repository:
        raise ValueError("Command requires an open PR against this repository")
    if pr["head"]["repo"] is None or pr["head"]["repo"]["full_name"] == repository:
        raise ValueError("Command requires a fork PR")
    if head is not None and pr["head"]["sha"] != head:
        raise ValueError("PR head changed during prerelease creation; tag will not be moved")
    if re.fullmatch(r"[0-9a-fA-F]{40}", pr["head"]["sha"]) is None:
        raise ValueError("PR head is not a full commit SHA")
    return pr


def create_prerelease(api: GitHubAPI, tag_api: GitHubAPI, event: dict, repository: str, workflow: str) -> tuple[str, str]:
    version = parse_command(event["comment"]["body"])
    if not event["issue"].get("pull_request"):
        raise ValueError("Command must be posted on a pull request")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+\.ya?ml", workflow):
        raise ValueError("Release workflow input must be a workflow filename")
    actor = event["comment"]["user"]["login"]
    permission = api.get(f"/repos/{repository}/collaborators/{quote(actor, safe='')}/permission")
    if permission["permission"] != "admin":
        raise ValueError("Only repository admins can create prereleases")
    if not tag_api.token:
        raise ValueError("PRERELEASE_TAG_TOKEN is required to create a prerelease tag")
    number = event["issue"]["number"]
    pr = validate_pr(api, repository, number)
    head = pr["head"]["sha"]
    ref_path = f"/repos/{repository}/git/ref/tags/{quote(version, safe='')}"
    try:
        api.get(ref_path)
    except LookupError:
        pass
    else:
        raise ValueError(f"Tag {version} already exists; use a new version")
    validate_pr(api, repository, number, head)
    api.get(f"/repos/{repository}/contents/.github/workflows/{quote(workflow, safe='')}?ref={quote(head, safe='')}")
    tag = tag_api.post(f"/repos/{repository}/git/refs", {"ref": f"refs/tags/{version}", "sha": head})
    if tag["object"]["sha"] != head:
        raise ValueError("Created tag does not point to the approved PR head")
    return version, head


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--release-workflow", required=True)
    args = parser.parse_args()
    event = json.loads(args.event.read_text(encoding="utf-8"))
    api = GitHubAPI(os.environ["GH_TOKEN"])
    tag_api = GitHubAPI(os.environ.get("PRERELEASE_TAG_TOKEN", ""))
    try:
        version, head = create_prerelease(api, tag_api, event, args.repository, args.release_workflow)
    except (ValueError, LookupError, PermissionError, RuntimeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write(f"Prerelease request failed for PR #{event['issue']['number']}: {error}\n")
        try:
            actor = event["comment"]["user"]["login"]
            permission = api.get(f"/repos/{args.repository}/collaborators/{quote(actor, safe='')}/permission")
            if permission["permission"] == "admin":
                api.post(f"/repos/{args.repository}/issues/{event['issue']['number']}/comments",
                         {"body": f"Prerelease request failed: {error}. Check the Actions run; any created tag was not moved."})
        except (LookupError, PermissionError, RuntimeError) as feedback_error:
            print(f"::warning::Could not post failure to the PR: {feedback_error}", file=sys.stderr)
        return 1
    summary = (f"Prerelease {version} from PR #{event['issue']['number']} at {head}; "
               f"created the tag. The tag push should trigger {args.release_workflow}; "
               "check the repository Actions page for the release run.")
    print(summary)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
        output.write(summary + "\n")
    try:
        api.post(f"/repos/{args.repository}/issues/{event['issue']['number']}/comments", {"body": summary})
    except (LookupError, PermissionError, RuntimeError) as feedback_error:
        print(f"::warning::Tag was created but PR feedback could not be posted: {feedback_error}",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())