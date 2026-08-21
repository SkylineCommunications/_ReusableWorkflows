#!/usr/bin/env python3
"""Validate a maintainer PR command against an immutable pull-request ref."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SHA_PATTERN = re.compile(r"[0-9a-fA-F]{40}")
SHA_BOUND_COMMANDS = {"/prepare-test", "/test", "/test-all"}
SUPPORTED_COMMANDS = SHA_BOUND_COMMANDS | {"/retest"}


class ValidationError(RuntimeError):
    """Raised when command authorization or ref validation fails."""


def normalize_sha(value: str, label: str) -> str:
    if not SHA_PATTERN.fullmatch(value):
        raise ValidationError(f"{label} must be a full 40-character SHA")
    return value.lower()


def parse_command(comment_body: str, allowed_command: str) -> tuple[str, str | None]:
    if allowed_command not in SUPPORTED_COMMANDS:
        raise ValidationError(f"Unsupported command {allowed_command}")
    if "\n" in comment_body or "\r" in comment_body:
        raise ValidationError("The command must be on a single line")

    match = re.fullmatch(r"(/prepare-test|/test|/test-all|/retest)(?: ([^ ]+))?", comment_body)
    if match is None or match.group(1) != allowed_command:
        raise ValidationError(f"Expected {allowed_command} with an optional full head SHA")

    supplied_sha = match.group(2)
    if allowed_command == "/retest" and supplied_sha is not None:
        raise ValidationError("/retest does not accept a SHA")
    if supplied_sha is not None:
        supplied_sha = normalize_sha(supplied_sha, "Supplied SHA")
    return allowed_command, supplied_sha


def validate(
    comment_body: str,
    allowed_command: str,
    is_cross_repository: bool,
    api_head_sha: str,
    fetched_head_sha: str,
) -> tuple[str, str]:
    command, supplied_sha = parse_command(comment_body, allowed_command)
    api_sha = normalize_sha(api_head_sha, "API head SHA")
    fetched_sha = normalize_sha(fetched_head_sha, "Fetched PR head SHA")

    if api_sha != fetched_sha:
        raise ValidationError(
            f"PR head moved while authorizing the command (API {api_sha}, fetched {fetched_sha})"
        )
    if supplied_sha is not None and supplied_sha != api_sha:
        raise ValidationError(
            f"Supplied SHA {supplied_sha} does not match the current PR head {api_sha}"
        )
    if is_cross_repository and command in SHA_BOUND_COMMANDS and supplied_sha is None:
        raise ValidationError(f"Fork PRs require `{command} {api_sha}`")

    return command, api_sha


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--comment-body", required=True)
    parser.add_argument("--allowed-command", choices=sorted(SUPPORTED_COMMANDS), required=True)
    parser.add_argument("--is-cross-repository", choices=("true", "false"), required=True)
    parser.add_argument("--api-head-sha", required=True)
    parser.add_argument("--fetched-head-sha", required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        command, head_sha = validate(
            args.comment_body,
            args.allowed_command,
            args.is_cross_repository == "true",
            args.api_head_sha,
            args.fetched_head_sha,
        )
    except ValidationError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    with args.github_output.open("a", encoding="utf-8") as output:
        output.write(f"command={command}\n")
        output.write(f"head_sha={head_sha}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())