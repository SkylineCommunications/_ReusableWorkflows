import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "update_managed_dependency_versions.py"
REPO_ROOT = SCRIPT_PATH.parents[2]
SPEC = importlib.util.spec_from_file_location("update_managed_dependency_versions", SCRIPT_PATH)
UPDATER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = UPDATER
SPEC.loader.exec_module(UPDATER)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


class ManagedDependencyUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo_root = Path(self.temporary_directory.name)
        self.master_path = self.repo_root / ".github/workflows/Master Workflow.yml"
        self.action_path = self.repo_root / ".github/actions/update-global-json-sdks/action.yml"
        self.test_workflow_path = self.repo_root / ".github/workflows/Test composite actions.yml"
        self.master_path.parent.mkdir(parents=True)
        self.action_path.parent.mkdir(parents=True)
        self._write_fixture_versions("4.1.0", "2.5.5", "2.5.5")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def _write_fixture_versions(self, app_version, sdk_version, expected_sdk_version):
        self.master_path.write_text(
            f"name: Main workflow\n\nenv:\n  VERSION_APPPACKAGEINSTALLER: '{app_version}'\n",
            encoding="utf-8",
        )
        self.action_path.write_text(
            "runs:\n  using: composite\n  steps:\n    - shell: pwsh\n      run: |\n"
            f"        $DATAMINER_SDK_VERSION = '{sdk_version}'\n",
            encoding="utf-8",
        )
        self.test_workflow_path.write_text(
            "jobs:\n  test:\n    steps:\n      - shell: bash\n"
            f'        run: echo "version={expected_sdk_version}" >> "$GITHUB_OUTPUT"\n',
            encoding="utf-8",
        )

    def _prepare(self, app_version="4.1.0", sdk_version="2.5.5"):
        return UPDATER.prepare_updates(
            self.repo_root,
            {"apppackageinstaller": app_version, "dataminer-sdk": sdk_version},
        )

    def test_parse_and_compare_numeric_versions(self):
        self.assertEqual((4, 1, 0), UPDATER.parse_stable_version("4.1.0"))
        self.assertGreater(UPDATER.compare_versions("2.10.0", "2.9.9"), 0)
        self.assertEqual(UPDATER.compare_versions("1.2.3", "1.2.3.0"), 0)

    def test_parse_rejects_prerelease_and_invalid_versions(self):
        for version in ("2.5.7-rc.1", "2.5", "v2.5.7", "02.5.7"):
            with self.subTest(version=version), self.assertRaises(UPDATER.UpdateError):
                UPDATER.parse_stable_version(version)

    def test_fetch_latest_stable_requires_exact_package_and_ignores_prerelease(self):
        payload = {
            "data": [
                {"id": "Other.Package", "versions": [{"version": "99.0.0", "downloads": 1}]},
                {
                    "id": "Skyline.DataMiner.Sdk",
                    "versions": [
                        {"version": "2.5.6", "downloads": 10},
                        {"version": "2.6.0-rc.1", "downloads": 5},
                        {"version": "2.5.7", "downloads": 2},
                    ],
                },
            ]
        }

        def opener(request, timeout):
            self.assertIn("prerelease=false", request.full_url)
            self.assertEqual(UPDATER.HTTP_TIMEOUT_SECONDS, timeout)
            return Response(json.dumps(payload).encode())

        self.assertEqual(
            "2.5.7",
            UPDATER.fetch_latest_stable("Skyline.DataMiner.Sdk", opener=opener),
        )

    def test_fetch_latest_stable_fails_closed_on_bad_results(self):
        payloads = (
            {},
            {"data": []},
            {"data": [{"id": "Skyline.DataMiner.Sdk", "versions": []}]},
            {
                "data": [
                    {"id": "Skyline.DataMiner.Sdk", "versions": []},
                    {"id": "skyline.dataminer.sdk", "versions": []},
                ]
            },
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                def opener(request, timeout, response=payload):
                    return Response(json.dumps(response).encode())

                with self.assertRaises(UPDATER.UpdateError):
                    UPDATER.fetch_latest_stable("Skyline.DataMiner.Sdk", opener=opener)

    def test_no_updates_when_versions_are_current_or_older(self):
        updates, current = self._prepare(app_version="4.0.0", sdk_version="2.5.5")
        self.assertEqual({}, updates)
        self.assertEqual(
            {"apppackageinstaller": "4.1.0", "dataminer-sdk": "2.5.5"}, current
        )

    def test_updates_apppackageinstaller_only(self):
        updates, _ = self._prepare(app_version="4.2.0")
        self.assertEqual({Path(".github/workflows/Master Workflow.yml")}, set(updates))
        UPDATER.write_updates(self.repo_root, updates)
        self.assertIn("VERSION_APPPACKAGEINSTALLER: '4.2.0'", self.master_path.read_text())
        self.assertIn("$DATAMINER_SDK_VERSION = '2.5.5'", self.action_path.read_text())

    def test_updates_sdk_pin_and_test_expectation_together(self):
        updates, _ = self._prepare(sdk_version="2.5.7")
        self.assertEqual(
            {
                Path(".github/actions/update-global-json-sdks/action.yml"),
                Path(".github/workflows/Test composite actions.yml"),
            },
            set(updates),
        )
        UPDATER.write_updates(self.repo_root, updates)
        self.assertIn("$DATAMINER_SDK_VERSION = '2.5.7'", self.action_path.read_text())
        self.assertIn('echo "version=2.5.7"', self.test_workflow_path.read_text())

    def test_updates_both_dependencies_and_second_run_is_idempotent(self):
        latest = {"apppackageinstaller": "4.2.0", "dataminer-sdk": "2.5.7"}
        updates, _ = UPDATER.prepare_updates(self.repo_root, latest)
        self.assertEqual(3, len(updates))
        UPDATER.write_updates(self.repo_root, updates)
        second_updates, current = UPDATER.prepare_updates(self.repo_root, latest)
        self.assertEqual({}, second_updates)
        self.assertEqual(latest, current)

    def test_real_repository_targets_are_present_and_synchronized(self):
        updates, current = UPDATER.prepare_updates(
            REPO_ROOT,
            {"apppackageinstaller": "0.0.0", "dataminer-sdk": "0.0.0"},
        )
        self.assertEqual({}, updates)
        self.assertEqual(
            {"apppackageinstaller", "dataminer-sdk"},
            set(current),
        )
        for version in current.values():
            UPDATER.parse_stable_version(version)

    def test_write_failure_rolls_back_already_replaced_files(self):
        latest = {"apppackageinstaller": "4.2.0", "dataminer-sdk": "2.5.7"}
        updates, _ = UPDATER.prepare_updates(self.repo_root, latest)
        originals = {
            path: UPDATER.read_text_preserving_newlines(self.repo_root / path)
            for path in updates
        }
        calls = 0

        def fail_second_replace(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected replacement failure")
            os.replace(source, destination)

        with self.assertRaisesRegex(UPDATER.UpdateError, "all replaced files were restored"):
            UPDATER.write_updates(self.repo_root, updates, replace_file=fail_second_replace)

        for path, original in originals.items():
            self.assertEqual(
                original,
                UPDATER.read_text_preserving_newlines(self.repo_root / path),
            )

    def test_update_preserves_crlf_line_endings(self):
        content = "name: Main workflow\r\n\r\nenv:\r\n  VERSION_APPPACKAGEINSTALLER: '4.1.0'\r\n"
        with self.master_path.open("w", encoding="utf-8", newline="") as master:
            master.write(content)

        updates, _ = self._prepare(app_version="4.2.0")
        UPDATER.write_updates(self.repo_root, updates)

        with self.master_path.open("r", encoding="utf-8", newline="") as master:
            updated = master.read()
        self.assertIn("VERSION_APPPACKAGEINSTALLER: '4.2.0'\r\n", updated)
        self.assertNotIn("\n", updated.replace("\r\n", ""))

    def test_mismatched_sdk_assignments_fail_before_any_write(self):
        original_master = self.master_path.read_text()
        self._write_fixture_versions("4.1.0", "2.5.5", "2.5.4")
        with self.assertRaisesRegex(UPDATER.UpdateError, "not synchronized"):
            self._prepare(app_version="4.2.0", sdk_version="2.5.7")
        self.assertEqual(original_master, self.master_path.read_text())
        self.assertIn("$DATAMINER_SDK_VERSION = '2.5.5'", self.action_path.read_text())
        self.assertIn('echo "version=2.5.4"', self.test_workflow_path.read_text())

    def test_missing_or_duplicate_assignment_fails_before_any_write(self):
        original_action = self.action_path.read_text()
        for content in (
            "name: missing\n",
            original_action + "        $DATAMINER_SDK_VERSION = '2.5.5'\n",
        ):
            with self.subTest(content=content):
                self.action_path.write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(UPDATER.UpdateError, "Expected one version assignment"):
                    self._prepare(sdk_version="2.5.7")
                self.assertIn("VERSION_APPPACKAGEINSTALLER: '4.1.0'", self.master_path.read_text())
        self.action_path.write_text(original_action, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
