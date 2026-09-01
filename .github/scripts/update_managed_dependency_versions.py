#!/usr/bin/env python3
"""Update centrally managed dependency versions from listed stable NuGet releases."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


NUGET_QUERY_URL = "https://azuresearch-usnc.nuget.org/query"
HTTP_TIMEOUT_SECONDS = 30


class UpdateError(RuntimeError):
    """Raised when dependency resolution or a repository update cannot be validated."""


@dataclass(frozen=True)
class Dependency:
    key: str
    package_id: str


@dataclass(frozen=True)
class Target:
    dependency_key: str
    relative_path: Path
    pattern: re.Pattern[str]


DEPENDENCIES = (
    Dependency("apppackageinstaller", "Skyline.DataMiner.Core.AppPackageInstaller"),
    Dependency("dataminer-sdk", "Skyline.DataMiner.Sdk"),
)

TARGETS = (
    Target(
        "apppackageinstaller",
        Path(".github/workflows/Master Workflow.yml"),
        re.compile(r"(?m)^(  VERSION_APPPACKAGEINSTALLER: ')([^']+)(')(?=\r?$)"),
    ),
    Target(
        "dataminer-sdk",
        Path(".github/actions/update-global-json-sdks/action.yml"),
        re.compile(r"(?m)^(        \$DATAMINER_SDK_VERSION = ')([^']+)(')(?=\r?$)"),
    ),
    Target(
        "dataminer-sdk",
        Path(".github/workflows/Test composite actions.yml"),
        re.compile(r'(?m)^(        run: echo "version=)([^"\r\n]+)(" >> "\$GITHUB_OUTPUT")(?=\r?$)'),
    ),
)


Version = tuple[int, ...]
OpenUrl = Callable[..., object]
ReplaceFile = Callable[[Path, Path], None]


def parse_stable_version(value: str) -> Version:
    if not re.fullmatch(r"(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){2,3}", value):
        raise UpdateError(f"Invalid stable NuGet version: {value!r}")
    return tuple(int(part) for part in value.split("."))


def compare_versions(left: str, right: str) -> int:
    left_parts = parse_stable_version(left)
    right_parts = parse_stable_version(right)
    width = max(len(left_parts), len(right_parts))
    normalized_left = left_parts + (0,) * (width - len(left_parts))
    normalized_right = right_parts + (0,) * (width - len(right_parts))
    return (normalized_left > normalized_right) - (normalized_left < normalized_right)


def fetch_latest_stable(
    package_id: str,
    *,
    query_url: str = NUGET_QUERY_URL,
    opener: OpenUrl = urllib.request.urlopen,
) -> str:
    query = urllib.parse.urlencode(
        {
            "q": f"packageid:{package_id}",
            "prerelease": "false",
            "semVerLevel": "2.0.0",
            "take": "20",
        }
    )
    request = urllib.request.Request(
        f"{query_url}?{query}",
        headers={"Accept": "application/json", "User-Agent": "managed-dependency-updater/1.0"},
    )

    try:
        with opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            payload = json.load(response)
    except (OSError, ValueError) as error:
        raise UpdateError(f"Failed to query NuGet for {package_id}: {error}") from error

    results = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        raise UpdateError(f"NuGet returned malformed data for {package_id}")

    exact_matches = [
        result
        for result in results
        if isinstance(result, dict)
        and isinstance(result.get("id"), str)
        and result["id"].casefold() == package_id.casefold()
    ]
    if len(exact_matches) != 1:
        raise UpdateError(
            f"Expected one exact NuGet result for {package_id}, found {len(exact_matches)}"
        )

    versions = exact_matches[0].get("versions")
    if not isinstance(versions, list):
        raise UpdateError(f"NuGet returned no version list for {package_id}")

    listed_stable_versions = []
    for entry in versions:
        # NuGet's Search Query Service only returns listed package versions.
        if not isinstance(entry, dict):
            continue
        version = entry.get("version")
        if not isinstance(version, str) or "-" in version:
            continue
        try:
            parse_stable_version(version)
        except UpdateError:
            continue
        listed_stable_versions.append(version)

    if not listed_stable_versions:
        raise UpdateError(f"NuGet returned no listed stable versions for {package_id}")

    return max(listed_stable_versions, key=lambda version: parse_stable_version(version))


def read_text_preserving_newlines(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as source:
        return source.read()


def prepare_updates(repo_root: Path, latest_versions: dict[str, str]) -> tuple[dict[Path, str], dict[str, str]]:
    contents: dict[Path, str] = {}
    current_versions: dict[str, set[str]] = {dependency.key: set() for dependency in DEPENDENCIES}

    for target in TARGETS:
        path = repo_root / target.relative_path
        try:
            content = read_text_preserving_newlines(path)
        except OSError as error:
            raise UpdateError(f"Failed to read {target.relative_path}: {error}") from error

        matches = list(target.pattern.finditer(content))
        if len(matches) != 1:
            raise UpdateError(
                f"Expected one version assignment in {target.relative_path}, found {len(matches)}"
            )
        current_versions[target.dependency_key].add(matches[0].group(2))
        contents[target.relative_path] = content

    resolved_current: dict[str, str] = {}
    for dependency in DEPENDENCIES:
        values = current_versions[dependency.key]
        if len(values) != 1:
            raise UpdateError(
                f"Current {dependency.package_id} assignments are not synchronized: {sorted(values)}"
            )
        resolved_current[dependency.key] = next(iter(values))

    updated_contents = dict(contents)
    for target in TARGETS:
        current = resolved_current[target.dependency_key]
        latest = latest_versions[target.dependency_key]
        if compare_versions(latest, current) <= 0:
            continue
        updated_contents[target.relative_path] = target.pattern.sub(
            lambda match: f"{match.group(1)}{latest}{match.group(3)}",
            updated_contents[target.relative_path],
            count=1,
        )

    changed = {
        relative_path: content
        for relative_path, content in updated_contents.items()
        if content != contents[relative_path]
    }
    return changed, resolved_current


def write_updates(
    repo_root: Path,
    updates: dict[Path, str],
    *,
    replace_file: ReplaceFile = os.replace,
) -> None:
    temporary_files: list[tuple[Path, Path, Path]] = []
    replaced_files: list[tuple[Path, Path]] = []
    try:
        for relative_path, content in updates.items():
            destination = repo_root / relative_path
            update_descriptor, update_name = tempfile.mkstemp(
                dir=destination.parent, prefix=f".{destination.name}.", suffix=".tmp"
            )
            backup_descriptor, backup_name = tempfile.mkstemp(
                dir=destination.parent, prefix=f".{destination.name}.", suffix=".bak"
            )
            update_path = Path(update_name)
            backup_path = Path(backup_name)
            with os.fdopen(update_descriptor, "w", encoding="utf-8", newline="") as update_file:
                update_file.write(content)
            with os.fdopen(backup_descriptor, "w", encoding="utf-8", newline="") as backup_file:
                backup_file.write(read_text_preserving_newlines(destination))
            temporary_files.append((update_path, backup_path, destination))

        for update_path, backup_path, destination in temporary_files:
            replace_file(update_path, destination)
            replaced_files.append((backup_path, destination))
    except OSError as error:
        rollback_errors = []
        for backup_path, destination in reversed(replaced_files):
            try:
                replace_file(backup_path, destination)
            except OSError as rollback_error:
                rollback_errors.append(f"{destination}: {rollback_error}")
        if rollback_errors:
            raise UpdateError(
                f"Failed to apply updates ({error}) and roll back files: {'; '.join(rollback_errors)}"
            ) from error
        raise UpdateError(f"Failed to apply updates; all replaced files were restored: {error}") from error
    finally:
        for update_path, backup_path, _ in temporary_files:
            update_path.unlink(missing_ok=True)
            backup_path.unlink(missing_ok=True)


def append_github_output(path: Path, values: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def append_step_summary(
    path: Path, current_versions: dict[str, str], latest_versions: dict[str, str]
) -> None:
    dependencies = {dependency.key: dependency for dependency in DEPENDENCIES}
    lines = ["## Managed dependency versions", "", "| Package | Current | Latest stable | Action |", "| --- | --- | --- | --- |"]
    for key in (dependency.key for dependency in DEPENDENCIES):
        current = current_versions[key]
        latest = latest_versions[key]
        action = "Update" if compare_versions(latest, current) > 0 else "No change"
        lines.append(f"| `{dependencies[key].package_id}` | `{current}` | `{latest}` | {action} |")
    with path.open("a", encoding="utf-8", newline="\n") as summary:
        summary.write("\n".join(lines) + "\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--query-url", default=NUGET_QUERY_URL)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--step-summary", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        latest_versions = {
            dependency.key: fetch_latest_stable(dependency.package_id, query_url=args.query_url)
            for dependency in DEPENDENCIES
        }
        updates, current_versions = prepare_updates(args.repo_root, latest_versions)
        write_updates(args.repo_root, updates)

        outputs = {"changed": str(bool(updates)).lower()}
        for dependency in DEPENDENCIES:
            output_key = dependency.key.replace("-", "_")
            outputs[f"{output_key}_current"] = current_versions[dependency.key]
            outputs[f"{output_key}_latest"] = latest_versions[dependency.key]
        if args.github_output:
            append_github_output(args.github_output, outputs)
        if args.step_summary:
            append_step_summary(args.step_summary, current_versions, latest_versions)
    except UpdateError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    for dependency in DEPENDENCIES:
        current = current_versions[dependency.key]
        latest = latest_versions[dependency.key]
        print(f"{dependency.package_id}: {current} -> {latest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
