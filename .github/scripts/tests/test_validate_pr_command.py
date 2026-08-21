import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from validate_pr_command import ValidationError, parse_command, validate  # noqa: E402


HEAD_SHA = "a" * 40
OTHER_SHA = "b" * 40


class ValidatePrCommandTests(unittest.TestCase):
    def test_internal_commands_allow_shorthand(self):
        for command in ("/prepare-test", "/test", "/test-all"):
            with self.subTest(command=command):
                self.assertEqual(
                    validate(command, command, False, HEAD_SHA, HEAD_SHA),
                    (command, HEAD_SHA),
                )

    def test_fork_commands_require_full_matching_sha(self):
        for command in ("/prepare-test", "/test", "/test-all"):
            with self.subTest(command=command):
                with self.assertRaises(ValidationError):
                    validate(command, command, True, HEAD_SHA, HEAD_SHA)
                self.assertEqual(
                    validate(f"{command} {HEAD_SHA.upper()}", command, True, HEAD_SHA, HEAD_SHA),
                    (command, HEAD_SHA),
                )

    def test_retest_accepts_no_sha_for_forks(self):
        self.assertEqual(
            validate("/retest", "/retest", True, HEAD_SHA, HEAD_SHA),
            ("/retest", HEAD_SHA),
        )
        with self.assertRaises(ValidationError):
            parse_command(f"/retest {HEAD_SHA}", "/retest")

    def test_rejects_malformed_commands_and_shas(self):
        invalid = (
            "/test abc123",
            f"/test {HEAD_SHA} trailing",
            f"/test  {HEAD_SHA}",
            f"/test\n{HEAD_SHA}",
        )
        for comment in invalid:
            with self.subTest(comment=comment), self.assertRaises(ValidationError):
                validate(comment, "/test", True, HEAD_SHA, HEAD_SHA)

    def test_rejects_supplied_api_or_fetched_sha_mismatch(self):
        cases = (
            (f"/test {OTHER_SHA}", HEAD_SHA, HEAD_SHA),
            (f"/test {HEAD_SHA}", HEAD_SHA, OTHER_SHA),
        )
        for comment, api_sha, fetched_sha in cases:
            with self.subTest(comment=comment), self.assertRaises(ValidationError):
                validate(comment, "/test", True, api_sha, fetched_sha)


if __name__ == "__main__":
    unittest.main()