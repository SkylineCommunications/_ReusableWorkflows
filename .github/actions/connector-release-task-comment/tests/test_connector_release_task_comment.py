from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs


ACTION_DIR = Path(__file__).resolve().parents[1]
SCRIPT = ACTION_DIR / "connector-release-task-comment.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"


spec = importlib.util.spec_from_file_location("connector_release_task_comment", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class FakeCollaborationServer(ThreadingHTTPServer):
    def __init__(self, server_address):
        super().__init__(server_address, FakeCollaborationHandler)
        self.task_state = {
            "100": {"Version": 7, "Comment": "old"},
            "123456": {"Version": 3, "Comment": "old"},
            "200": {"Version": 11, "Comment": "old"},
        }
        self.request_log = []
        self.fail_patch = False
        self.partial_failure = False
        self.conflict_once = False
        self.conflict_seen = False


class FakeCollaborationHandler(BaseHTTPRequestHandler):
    server: FakeCollaborationServer

    def log_message(self, format, *args):
        return

    def _record(self, method, path, body=None):
        self.server.request_log.append({"method": method, "path": path, "body": body})

    def _json(self, status, value):
        data = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length)

    def do_POST(self):
        body = self._read_body()
        self._record("POST", self.path, body)
        if self.path == "/Token":
            values = parse_qs(body.decode("utf-8"))
            if values.get("username") != ["test-user"] or values.get("password") != ["test-password"]:
                self._json(401, {"error": "invalid_grant"})
            else:
                self._json(200, {"access_token": "test-access-token"})
            return
        self._json(404, {})

    def do_GET(self):
        self._record("GET", self.path)
        if self.headers.get("Authorization") != "Bearer test-access-token":
            self._json(401, {})
            return
        prefix = "/api/tasks/byid?ids[]="
        if not self.path.startswith(prefix):
            self._json(404, {})
            return
        task_id = parse_qs(self.path.split("?", 1)[1]).get("ids[]", [""])[0]
        if task_id not in self.server.task_state:
            self._json(404, {})
            return
        record = self.server.task_state[task_id]
        self._json(
            200,
            {"ID": int(task_id), "Version": record["Version"], "Comment": record["Comment"]},
        )

    def do_PATCH(self):
        body = self._read_body()
        try:
            decoded = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            decoded = None
        self._record("PATCH", self.path, decoded)
        if self.headers.get("Authorization") != "Bearer test-access-token":
            self._json(401, {})
            return
        if self.path != "/api/tasks/batch":
            self._json(404, {})
            return
        if self.server.fail_patch:
            self._json(500, {"error": "simulated failure"})
            return
        if self.server.partial_failure:
            self._json(207, [{"ID": 123456, "success": False, "error": "simulated task failure"}])
            return
        if self.server.conflict_once and not self.server.conflict_seen:
            self.server.conflict_seen = True
            self._json(409, {"error": "version conflict"})
            return
        if not isinstance(decoded, list):
            self._json(400, {"error": "expected task array"})
            return
        result = []
        for item in decoded:
            task_id = str(item.get("ID"))
            current = self.server.task_state.get(task_id)
            if current is None or item.get("Version") != current["Version"]:
                self._json(409, {"error": "version conflict"})
                return
            current["Version"] += 1
            current["Comment"] = item.get("Comment")
            result.append({"ID": int(task_id), "Version": current["Version"], "Comment": current["Comment"]})
        self._json(200, result)


def start_server():
    server = FakeCollaborationServer(("127.0.0.1", 0))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def stop_server(server, thread):
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


class ConnectorReleaseTaskCommentTests(unittest.TestCase):
    def run_script(self, fixture, tag, server=None, quality="true", dry_run="false", credentials=True):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            output = temp_path / "output.txt"
            summary = temp_path / "summary.md"
            env = os.environ.copy()
            env.update(
                {
                    "PROTOCOL_FILE": str(fixture),
                    "RELEASE_TAG": tag,
                    "QUALITY_GATES_PASSED": quality,
                    "DRY_RUN": dry_run,
                    "GITHUB_OUTPUT": str(output),
                    "GITHUB_STEP_SUMMARY": str(summary),
                    "GITHUB_WORKSPACE": temp,
                    "PYTHONUNBUFFERED": "1",
                }
            )
            if server is not None:
                env["API_BASE_URL"] = f"http://127.0.0.1:{server.server_port}"
                env["SKYLINE_TOKEN_URL"] = f"http://127.0.0.1:{server.server_port}/Token"
            if credentials:
                env["SKYLINE_USERNAME_OVERRIDE"] = "test-user"
                env["SKYLINE_PASSWORD_OVERRIDE"] = "test-password"
            else:
                env.pop("SKYLINE_USERNAME_OVERRIDE", None)
                env.pop("SKYLINE_PASSWORD_OVERRIDE", None)
                env.pop("SKYLINE_USERNAME", None)
                env.pop("SKYLINE_PASSWORD", None)
            completed = subprocess.run(
                [sys.executable, str(SCRIPT)],
                cwd=ACTION_DIR,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            outputs = {}
            if output.exists():
                for line in output.read_text(encoding="utf-8").splitlines():
                    key, value = line.split("=", 1)
                    outputs[key] = value
            comment = (temp_path / "connector-release-comment.md").read_text(encoding="utf-8") if (temp_path / "connector-release-comment.md").exists() else ""
            summary_text = summary.read_text(encoding="utf-8") if summary.exists() else ""
            return completed, outputs, comment, summary_text

    def test_arkona_comment_and_namespace(self):
        metadata = module.parse_release_metadata(
            FIXTURES / "arkona-namespaced.xml", "1.0.0.1", True
        )
        self.assertEqual(metadata.connector_name, "Arkona Technologies AT300")
        self.assertEqual(metadata.released_version, "1.0.0.1")
        self.assertEqual(metadata.branch_comment, "Main Branch")
        self.assertEqual(metadata.task_ids, ("123456",))
        self.assertEqual(
            metadata.comment,
            "Connector 'Arkona Technologies AT300' with version '1.0.0.1' has been released.\n"
            "Branch Comment: Main Branch\n"
            "NF: Initial version\n\n"
            "** Verified as compliant with all SLC quality gates. **",
        )

    def test_multiple_changes_and_duplicate_task_ids_are_deduplicated(self):
        metadata = module.parse_release_metadata(
            FIXTURES / "duplicate-task-ids.xml", "1.0.0.2", False
        )
        self.assertEqual(metadata.task_ids, ("200", "100"))
        self.assertEqual(
            metadata.comment,
            "Connector 'Example Connector' with version '1.0.0.2' has been released.\n"
            "Branch Comment: Feature Branch\n"
            "F: Corrected a polling issue\n"
            "C: Updated the connection handling\n"
            "NF: Added a status table",
        )
        self.assertNotIn("SLC quality gates", metadata.comment)

    def test_multiple_branches_selects_the_released_entry(self):
        metadata = module.parse_release_metadata(
            FIXTURES / "multiple-branches.xml", "2.0.0.1", True
        )
        self.assertEqual(metadata.branch_comment, "Release Branch")
        self.assertEqual(metadata.task_ids, ("300",))
        self.assertIn("NF: Selected feature", metadata.comment)
        self.assertNotIn("Old fix", metadata.comment)

    def test_missing_references_fails_closed(self):
        with self.assertRaisesRegex(module.ReleaseCommentError, "no References/TaskId"):
            module.parse_release_metadata(
                FIXTURES / "missing-references.xml", "1.0.0.1", True
            )

    def test_xml_escaped_metadata_is_decoded_without_rewriting_source_text(self):
        metadata = module.parse_release_metadata(
            FIXTURES / "escaped-text.xml", "1.0.0.1", False
        )
        self.assertEqual(metadata.connector_name, "Connector & One")
        self.assertEqual(metadata.branch_comment, "Main & Branch")
        self.assertIn("NF: Supports <tag> values", metadata.comment)
    def test_stable_and_prerelease_tags(self):
        self.assertEqual(module.stable_tag_version("v1.2.3.4"), "1.2.3.4")
        self.assertEqual(module.stable_tag_version("1.2.3"), "1.2.3")
        for tag in ("1.2.3-beta.1", "main", "", "release-1.2.3"):
            with self.assertRaises(module.ReleaseCommentError):
                module.stable_tag_version(tag)

    def test_missing_metadata_fails_closed(self):
        with self.assertRaisesRegex(module.ReleaseCommentError, "VersionHistory"):
            module.parse_release_metadata(
                FIXTURES / "missing-version-history.xml", "1.0.0.1", True
            )
        with self.assertRaisesRegex(module.ReleaseCommentError, "not found"):
            module.parse_release_metadata(
                FIXTURES / "arkona-namespaced.xml", "1.0.0.2", True
            )

    def test_batch_endpoint_uses_current_versions_and_reruns_safely(self):
        server, thread = start_server()
        try:
            first, outputs, comment, _ = self.run_script(
                FIXTURES / "arkona-namespaced.xml", "1.0.0.1", server
            )
            second, second_outputs, second_comment, _ = self.run_script(
                FIXTURES / "arkona-namespaced.xml", "1.0.0.1", server
            )
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual(outputs["status"], "success")
            self.assertEqual(second_outputs["task-ids"], '["123456"]')
            self.assertEqual(comment, second_comment)
            patches = [entry for entry in server.request_log if entry["method"] == "PATCH"]
            self.assertEqual([entry["path"] for entry in patches], ["/api/tasks/batch", "/api/tasks/batch"])
            self.assertEqual(patches[0]["body"][0]["ID"], 123456)
            self.assertEqual(patches[0]["body"][0]["Version"], 3)
            self.assertEqual(patches[1]["body"][0]["Version"], 4)
            self.assertTrue(all("Comment" in entry["body"][0] for entry in patches))
            self.assertFalse(any("/api/comments" in entry["path"] for entry in server.request_log))
        finally:
            stop_server(server, thread)

    def test_batch_contains_each_unique_task_once(self):
        server, thread = start_server()
        try:
            completed, outputs, _, _ = self.run_script(
                FIXTURES / "duplicate-task-ids.xml", "1.0.0.2", server, quality="false"
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(outputs["task-ids"], '["200","100"]')
            patches = [entry for entry in server.request_log if entry["method"] == "PATCH"]
            self.assertEqual([item["ID"] for item in patches[0]["body"]], [200, 100])
            self.assertEqual(len(patches[0]["body"]), 2)
        finally:
            stop_server(server, thread)
    def test_optimistic_concurrency_conflict_is_re_read_once(self):
        server, thread = start_server()
        server.conflict_once = True
        try:
            completed, outputs, _, _ = self.run_script(
                FIXTURES / "arkona-namespaced.xml", "1.0.0.1", server
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(outputs["status"], "success")
            self.assertEqual(len([e for e in server.request_log if e["method"] == "PATCH"]), 2)
            self.assertGreaterEqual(len([e for e in server.request_log if e["method"] == "GET"]), 2)
        finally:
            stop_server(server, thread)

    def test_api_failure_is_reported_without_exposing_credentials(self):
        server, thread = start_server()
        server.fail_patch = True
        try:
            completed, outputs, _, summary = self.run_script(
                FIXTURES / "arkona-namespaced.xml", "1.0.0.1", server
            )
            self.assertEqual(completed.returncode, 1)
            self.assertEqual(outputs["status"], "failed")
            combined = completed.stdout + completed.stderr + summary
            self.assertIn("HTTP 500", combined)
            self.assertIn("Connector release task comments failed", combined)
            self.assertNotIn("test-password", combined)
            # The workflow caller uses continue-on-error for this action; the
            # script's non-zero result is therefore visible but non-blocking.
        finally:
            stop_server(server, thread)

    def test_partial_batch_failure_identifies_task_id(self):
        server, thread = start_server()
        server.partial_failure = True
        try:
            completed, outputs, _, _ = self.run_script(
                FIXTURES / "arkona-namespaced.xml", "1.0.0.1", server
            )
            self.assertEqual(completed.returncode, 1)
            self.assertEqual(outputs["status"], "failed")
            self.assertIn("123456", completed.stdout)
        finally:
            stop_server(server, thread)
    def test_missing_credentials_are_clear_and_non_networking(self):
        server, thread = start_server()
        try:
            completed, outputs, _, _ = self.run_script(
                FIXTURES / "arkona-namespaced.xml", "1.0.0.1", server, credentials=False
            )
            self.assertEqual(completed.returncode, 1)
            self.assertEqual(outputs["status"], "failed")
            self.assertIn("SKYLINE_USERNAME and SKYLINE_PASSWORD are required", completed.stdout)
            self.assertFalse(server.request_log)
        finally:
            stop_server(server, thread)

    def test_dry_run_exercises_script_without_credentials(self):
        completed, outputs, comment, summary = self.run_script(
            FIXTURES / "arkona-namespaced.xml", "1.0.0.1", dry_run="true", credentials=False
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(outputs["status"], "success")
        self.assertIn("Arkona Technologies AT300", comment)
        self.assertIn("Dry run", completed.stdout)
        self.assertIn("success", summary)


if __name__ == "__main__":
    unittest.main()
