#!/usr/bin/env python3
"""Render and publish a connector release comment to Collaboration tasks.

The script deliberately keeps the release metadata parser independent from GitHub
and the Collaboration API.  The composite action supplies all workflow values via
environment variables, which also makes this file straightforward to test offline.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


STABLE_TAG_PATTERN = re.compile(
    r"^v?\d+\.\d+\.\d+(?:\.\d+)?(?:\+[0-9A-Za-z.-]+)?$"
)
CHANGE_LABELS = {
    "fix": "F",
    "change": "C",
    "newfeature": "NF",
}
QUALITY_GATE_LINE = "** Verified as compliant with all SLC quality gates. **"


class ReleaseCommentError(RuntimeError):
    """An expected, safe-to-report release comment failure."""


@dataclass(frozen=True)
class ReleaseMetadata:
    connector_name: str
    released_version: str
    branch_comment: str
    changes: tuple[tuple[str, str], ...]
    task_ids: tuple[str, ...]
    comment: str


@dataclass(frozen=True)
class HttpResult:
    status: int
    body: Any


class ApiFailure(ReleaseCommentError):
    """An API operation failed without retaining a response secret or body."""


def local_name(tag: str) -> str:
    """Return an XML local name for both namespaced and unqualified elements."""
    return tag.rsplit("}", 1)[-1]


def direct_child(parent: ET.Element, expected: str) -> ET.Element | None:
    for child in list(parent):
        if local_name(child.tag) == expected:
            return child
    return None


def direct_children(parent: ET.Element, expected: str) -> list[ET.Element]:
    return [child for child in list(parent) if local_name(child.tag) == expected]


def text_of(element: ET.Element | None) -> str:
    if element is None:
        return ""
    # Version-history text is intentionally preserved apart from XML indentation
    # around the value.  Do not lowercase or otherwise rewrite source text.
    return "".join(element.itertext()).replace("\r\n", "\n").replace("\r", "\n").strip()


def required_id(element: ET.Element, path: str) -> str:
    value = (element.attrib.get("id") or "").strip()
    if not value or not re.fullmatch(r"\d+", value):
        raise ReleaseCommentError(f"Missing or invalid numeric version-history id at {path}.")
    # IDs form the four components of a DataMiner protocol version.  Canonicalise
    # leading zeroes so a schema-valid id still compares with a normal tag.
    return str(int(value))


def normalize_version(value: str) -> str:
    value = value.strip()
    if value.lower().startswith("v"):
        value = value[1:]
    return value


def stable_tag_version(tag: str) -> str:
    """Validate a stable connector tag and return its version without an optional v."""
    value = (tag or "").strip()
    if not value or not STABLE_TAG_PATTERN.fullmatch(value):
        raise ReleaseCommentError(
            f"Release tag '{value}' is not a stable connector version tag; "
            "prerelease and non-version tags are ignored."
        )
    return normalize_version(value)


def _find_matching_versions(history: ET.Element, target: str) -> list[tuple[str, str, ET.Element]]:
    branches_container = direct_child(history, "Branches")
    if branches_container is None:
        raise ReleaseCommentError("protocol.xml is missing VersionHistory/Branches.")

    matches: list[tuple[str, str, ET.Element]] = []
    for branch in direct_children(branches_container, "Branch"):
        branch_id = required_id(branch, "VersionHistory/Branches/Branch")
        branch_comment = text_of(direct_child(branch, "Comment"))
        systems = direct_child(branch, "SystemVersions")
        if systems is None:
            continue
        for system in direct_children(systems, "SystemVersion"):
            system_id = required_id(system, "VersionHistory/.../SystemVersion")
            majors = direct_child(system, "MajorVersions")
            if majors is None:
                continue
            for major in direct_children(majors, "MajorVersion"):
                major_id = required_id(major, "VersionHistory/.../MajorVersion")
                minors = direct_child(major, "MinorVersions")
                if minors is None:
                    continue
                for minor in direct_children(minors, "MinorVersion"):
                    minor_id = required_id(minor, "VersionHistory/.../MinorVersion")
                    version = f"{branch_id}.{system_id}.{major_id}.{minor_id}"
                    if normalize_version(version) == normalize_version(target):
                        matches.append((version, branch_comment, minor))
    return matches


def parse_release_metadata(
    protocol_file: str | os.PathLike[str], release_tag: str, quality_gates_passed: bool
) -> ReleaseMetadata:
    target_version = stable_tag_version(release_tag)
    path = Path(protocol_file)
    if not path.is_file():
        raise ReleaseCommentError(f"Connector metadata file was not found: {path}.")

    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        raise ReleaseCommentError(f"Could not read connector metadata from {path}.") from exc

    if local_name(root.tag) != "Protocol":
        raise ReleaseCommentError("Connector metadata root element is not Protocol.")

    connector_name = text_of(direct_child(root, "Name"))
    if not connector_name:
        raise ReleaseCommentError("protocol.xml is missing the connector Name.")

    history = direct_child(root, "VersionHistory")
    if history is None:
        raise ReleaseCommentError("protocol.xml is missing VersionHistory.")

    matches = _find_matching_versions(history, target_version)
    if not matches:
        raise ReleaseCommentError(
            f"Version-history entry for released version '{target_version}' was not found."
        )
    if len(matches) > 1:
        raise ReleaseCommentError(
            f"Version-history contains {len(matches)} entries for released version '{target_version}'."
        )

    released_version, branch_comment, minor = matches[0]
    if not branch_comment:
        raise ReleaseCommentError(f"Released version '{released_version}' has no branch Comment.")

    changes_container = direct_child(minor, "Changes")
    if changes_container is None:
        raise ReleaseCommentError(f"Released version '{released_version}' has no Changes entry.")

    changes: list[tuple[str, str]] = []
    for change in list(changes_container):
        label = CHANGE_LABELS.get(local_name(change.tag).lower())
        description = text_of(change)
        if label is None:
            # The protocol schema may gain a new change kind.  Do not silently
            # put an unknown entry in a historical comment.
            raise ReleaseCommentError(
                f"Released version '{released_version}' contains unsupported change type "
                f"'{local_name(change.tag)}'."
            )
        if not description:
            raise ReleaseCommentError(
                f"Released version '{released_version}' contains an empty {local_name(change.tag)} entry."
            )
        changes.append((label, description))
    if not changes:
        raise ReleaseCommentError(f"Released version '{released_version}' has no change entries.")

    references = direct_child(minor, "References")
    if references is None:
        raise ReleaseCommentError(f"Released version '{released_version}' has no References/TaskId entries.")

    task_ids: list[str] = []
    seen: set[str] = set()
    for task in direct_children(references, "TaskId"):
        raw_task_id = text_of(task)
        if not re.fullmatch(r"\d+", raw_task_id or ""):
            raise ReleaseCommentError(
                f"Released version '{released_version}' contains an invalid TaskId."
            )
        task_id = str(int(raw_task_id))
        if task_id not in seen:
            seen.add(task_id)
            task_ids.append(task_id)
    if not task_ids:
        raise ReleaseCommentError(f"Released version '{released_version}' has no TaskId values.")

    lines = [
        f"Connector '{connector_name}' with version '{released_version}' has been released.",
        f"Branch Comment: {branch_comment}",
    ]
    lines.extend(f"{label}: {description}" for label, description in changes)
    comment = "\n".join(lines)
    if quality_gates_passed:
        comment += f"\n\n{QUALITY_GATE_LINE}"

    return ReleaseMetadata(
        connector_name=connector_name,
        released_version=released_version,
        branch_comment=branch_comment,
        changes=tuple(changes),
        task_ids=tuple(task_ids),
        comment=comment,
    )


def _case_insensitive_value(value: dict[str, Any], names: Iterable[str]) -> Any:
    wanted = {name.lower() for name in names}
    for key, candidate in value.items():
        if str(key).lower() in wanted:
            return candidate
    return None


def _dicts_in(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _dicts_in(child)
    elif isinstance(value, list):
        for child in value:
            yield from _dicts_in(child)


def _normalized_task_id(value: Any) -> str | None:
    if value is None:
        return None
    raw = str(value).strip()
    if not raw:
        return None
    try:
        return str(int(raw))
    except (TypeError, ValueError):
        return raw


def _same_task_id(value: Any, expected: str) -> bool:
    return _normalized_task_id(value) == expected


def _task_record(body: Any, task_id: str) -> dict[str, Any] | None:
    fallback: dict[str, Any] | None = None
    for candidate in _dicts_in(body):
        candidate_id = _case_insensitive_value(candidate, ("ID", "TaskId", "task_id"))
        version = _case_insensitive_value(candidate, ("Version",))
        if version is not None and fallback is None:
            fallback = candidate
        if candidate_id is not None and _same_task_id(candidate_id, task_id):
            return candidate
    return fallback


def _api_url(base: str, path: str) -> str:
    if re.match(r"^https?://", path, re.IGNORECASE):
        return path
    return base.rstrip("/") + "/" + path.lstrip("/")


class CollaborationApi:
    def __init__(self, base_url: str, token_url: str, timeout: float = 30.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.token_url = token_url
        self.timeout = timeout
        self.token = ""

    @staticmethod
    def _safe_http_error(path: str, status: int, reason: str | None = None) -> ApiFailure:
        suffix = f" ({reason})" if reason else ""
        return ApiFailure(f"Collaboration API request to {path} failed with HTTP {status}{suffix}.")

    def _request(
        self,
        method: str,
        url: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> HttpResult:
        request_headers = {"Accept": "application/json", **(headers or {})}
        request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
                status = int(response.status)
        except urllib.error.HTTPError as exc:
            # Consume and discard the body.  Error responses must never be copied
            # into logs because an upstream service could echo sensitive fields.
            try:
                exc.read()
            finally:
                exc.close()
            return HttpResult(int(exc.code), None)
        except urllib.error.URLError as exc:
            # Do not echo a proxy or transport detail that might contain credentials.
            reason_type = type(getattr(exc, "reason", None)).__name__
            raise ApiFailure(
                f"Collaboration API request to {urlparse_path(url)} failed ({reason_type})."
            ) from exc
        except TimeoutError as exc:
            raise ApiFailure(f"Collaboration API request to {urlparse_path(url)} timed out.") from exc

        if not raw:
            return HttpResult(status, None)
        try:
            return HttpResult(status, json.loads(raw.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return HttpResult(status, None)

    def authenticate(self, username: str, password: str) -> None:
        form = urllib.parse.urlencode(
            {"grant_type": "password", "username": username, "password": password}
        ).encode("utf-8")
        result = self._request(
            "POST",
            self.token_url,
            body=form,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if not 200 <= result.status < 300:
            raise self._safe_http_error("POST /Token", result.status)
        if not isinstance(result.body, dict):
            raise ApiFailure("Token response did not contain an access token.")
        token = _case_insensitive_value(result.body, ("access_token", "accessToken", "token"))
        if not isinstance(token, str) or not token:
            raise ApiFailure("Token response did not contain an access token.")
        self.token = token

    def read_task(self, task_id: str) -> tuple[Any, Any]:
        path = f"/api/tasks/byid?ids[]={urllib.parse.quote(task_id, safe='')}"
        result = self._request(
            "GET",
            _api_url(self.base_url, path),
            headers={"Authorization": f"Bearer {self.token}"},
        )
        if not 200 <= result.status < 300:
            raise self._safe_http_error(f"GET {path}", result.status)
        record = _task_record(result.body, task_id)
        if record is None:
            raise ApiFailure(f"GET {path} did not return task {task_id}.")
        returned_id = _case_insensitive_value(record, ("ID", "TaskId", "task_id"))
        if returned_id is not None and not _same_task_id(returned_id, task_id):
            raise ApiFailure(f"GET {path} returned a different task ID.")
        version = _case_insensitive_value(record, ("Version",))
        if version is None or (isinstance(version, str) and not version.strip()):
            raise ApiFailure(f"GET {path} did not return the current task version.")
        try:
            current_version = int(version)
        except (TypeError, ValueError) as exc:
            raise ApiFailure(f"GET {path} returned a non-numeric task version.") from exc
        return returned_id if returned_id is not None else int(task_id), current_version

    def patch_tasks(self, payload: list[dict[str, Any]]) -> HttpResult:
        path = "/api/tasks/batch"
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        return self._request(
            "PATCH",
            _api_url(self.base_url, path),
            body=data,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )


def urlparse_path(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    return parsed.path or "/"


def _response_has_failure(body: Any, task_ids: set[str]) -> set[str]:
    failed: set[str] = set()

    def add_item(value: Any) -> None:
        normalized = _normalized_task_id(value)
        if normalized is None or normalized not in task_ids:
            failed.update(task_ids)
        else:
            failed.add(normalized)

    if isinstance(body, dict):
        success = _case_insensitive_value(body, ("success", "succeeded"))
        if success is False:
            failed.update(task_ids)
        for key in ("errors", "failures", "failed", "invalid"):
            value = _case_insensitive_value(body, (key,))
            if not value:
                continue
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        add_item(_case_insensitive_value(item, ("ID", "TaskId", "task_id")))
                    else:
                        failed.update(task_ids)
            else:
                failed.update(task_ids)

    for record in _dicts_in(body):
        item_id = _case_insensitive_value(record, ("ID", "TaskId", "task_id"))
        status = _case_insensitive_value(record, ("success", "succeeded", "ok"))
        error = _case_insensitive_value(record, ("error", "errors", "failure", "failures"))
        if status is False or error:
            add_item(item_id)

    return failed


def _verify_patch_result(result: HttpResult, payload: list[dict[str, Any]]) -> None:
    task_ids = {str(int(item["ID"])) for item in payload}
    failed = _response_has_failure(result.body, task_ids)
    if failed:
        succeeded = task_ids - failed
        detail = "Batch task update reported failures for task IDs: " + ", ".join(sorted(failed))
        if succeeded:
            detail += "; successful task IDs: " + ", ".join(sorted(succeeded))
        raise ApiFailure(detail)
    if isinstance(result.body, dict):
        success = _case_insensitive_value(result.body, ("success", "succeeded"))
        if success is False:
            raise ApiFailure("Batch task update reported failure for the requested task IDs.")

    returned_records = [
        record
        for record in _dicts_in(result.body)
        if _case_insensitive_value(record, ("ID", "TaskId", "task_id")) is not None
    ]
    if not returned_records:
        # 200/204 responses without a representation are valid for PATCH APIs.
        return

    seen: set[str] = set()
    for record in returned_records:
        raw_id = _case_insensitive_value(record, ("ID", "TaskId", "task_id"))
        normalized_id = str(raw_id)
        try:
            normalized_id = str(int(normalized_id))
        except (TypeError, ValueError):
            pass
        if normalized_id not in task_ids:
            continue
        seen.add(normalized_id)
        returned_comment = _case_insensitive_value(record, ("Comment",))
        expected_comment = next(
            item["Comment"] for item in payload if str(int(item["ID"])) == normalized_id
        )
        if returned_comment is not None and returned_comment != expected_comment:
            raise ApiFailure(f"Batch task update returned an unexpected comment for task {normalized_id}.")
    missing = task_ids - seen
    if missing:
        raise ApiFailure("Batch task update did not return task IDs: " + ", ".join(sorted(missing)))


def _credentials() -> tuple[str, str]:
    # Explicit caller secrets win over optional Key Vault-loaded variables.  The
    # override names are deliberately distinct so a step-level env cannot hide a
    # value exported by load-secrets through GITHUB_ENV.
    username = os.environ.get("SKYLINE_USERNAME_OVERRIDE") or os.environ.get("SKYLINE_USERNAME", "")
    password = os.environ.get("SKYLINE_PASSWORD_OVERRIDE") or os.environ.get("SKYLINE_PASSWORD", "")
    if not username or not password:
        raise ReleaseCommentError(
            "SKYLINE_USERNAME and SKYLINE_PASSWORD are required for collaboration task updates; "
            "configure the optional workflow secrets or the Skyline Key Vault values."
        )
    return username, password


def _write_output(values: dict[str, str]) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8", newline="\n") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def _write_summary(metadata: ReleaseMetadata | None, status: str, failure: str | None = None) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    lines = [f"## Connector release collaboration comments: {'✅' if status == 'success' else '❌'} {status}", ""]
    if metadata is not None:
        lines.extend(
            [
                f"- Connector: `{metadata.connector_name}`",
                f"- Version: `{metadata.released_version}`",
                f"- Task IDs: `{', '.join(metadata.task_ids)}`",
            ]
        )
    if failure:
        lines.extend(["", f"**Failure:** {failure}"])
    with open(summary_path, "a", encoding="utf-8", newline="\n") as summary:
        summary.write("\n".join(lines) + "\n")


def _write_comment(metadata: ReleaseMetadata) -> str:
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", os.getcwd()))
    workspace.mkdir(parents=True, exist_ok=True)
    comment_path = workspace / "connector-release-comment.md"
    comment_path.write_text(metadata.comment + "\n", encoding="utf-8", newline="\n")
    return str(comment_path)


def _run_api(metadata: ReleaseMetadata) -> None:
    username, password = _credentials()
    base_url = os.environ.get("API_BASE_URL", "https://api.skyline.be").strip().rstrip("/")
    token_url = os.environ.get("SKYLINE_TOKEN_URL", "https://api.skyline.be/Token").strip()
    if not base_url or not token_url:
        raise ReleaseCommentError("Collaboration API base URL and token URL must not be empty.")
    try:
        timeout = float(os.environ.get("API_TIMEOUT_SECONDS", "30"))
    except ValueError as exc:
        raise ReleaseCommentError("API_TIMEOUT_SECONDS must be numeric.") from exc
    client = CollaborationApi(base_url, token_url, timeout=max(1.0, timeout))
    client.authenticate(username, password)

    for attempt in range(2):
        payload: list[dict[str, Any]] = []
        for task_id in metadata.task_ids:
            current_id, version = client.read_task(task_id)
            try:
                current_id_int = int(str(current_id))
            except (TypeError, ValueError) as exc:
                raise ApiFailure(f"Task {task_id} returned a non-numeric ID.") from exc
            payload.append({"ID": current_id_int, "Version": version, "Comment": metadata.comment})

        result = client.patch_tasks(payload)
        if result.status in (409, 412) and attempt == 0:
            print("Optimistic-concurrency conflict while updating task comments; re-reading task versions once.")
            continue
        if not 200 <= result.status < 300:
            raise client._safe_http_error("PATCH /api/tasks/batch", result.status)
        _verify_patch_result(result, payload)
        print("Updated collaboration comments for task IDs: " + ", ".join(metadata.task_ids))
        return
    raise ApiFailure("Batch task update still conflicted after one safe retry.")


def main() -> int:
    metadata: ReleaseMetadata | None = None
    outputs = {"status": "failed", "connector-name": "", "released-version": "", "task-ids": "[]", "comment-file": ""}
    try:
        quality = os.environ.get("QUALITY_GATES_PASSED", "false").strip().lower() in {
            "1",
            "true",
            "yes",
            "passed",
            "success",
        }
        protocol_file = os.environ.get("PROTOCOL_FILE", "protocol.xml")
        if not os.path.isabs(protocol_file):
            protocol_file = str(Path(os.environ.get("GITHUB_WORKSPACE", os.getcwd())) / protocol_file)
        metadata = parse_release_metadata(protocol_file, os.environ.get("RELEASE_TAG", ""), quality)
        comment_file = _write_comment(metadata)
        outputs.update(
            {
                "connector-name": metadata.connector_name,
                "released-version": metadata.released_version,
                "task-ids": json.dumps(list(metadata.task_ids), separators=(",", ":")),
                "comment-file": comment_file,
            }
        )

        if os.environ.get("DRY_RUN", "false").strip().lower() in {"1", "true", "yes"}:
            print("Dry run: parsed release metadata; no Collaboration API request was made.")
        else:
            _run_api(metadata)

        outputs["status"] = "success"
        _write_output(outputs)
        _write_summary(metadata, "success")
        return 0
    except ReleaseCommentError as exc:
        # Keep the annotation useful while ensuring no request body, token, or
        # password is ever printed.  Expected errors are intentionally concise.
        message = str(exc).replace("\r", " ").replace("\n", " ")
        print(f"::error title=Connector release task comments::{message}")
        print(f"Connector release task comments failed: {message}")
        _write_output(outputs)
        _write_summary(metadata, "failed", message)
        return 1
    except Exception as exc:  # pragma: no cover - defensive last-resort reporting
        message = f"Unexpected connector release task comment error ({type(exc).__name__})."
        print(f"::error title=Connector release task comments::{message}")
        _write_output(outputs)
        _write_summary(metadata, "failed", message)
        return 1


if __name__ == "__main__":
    sys.exit(main())
