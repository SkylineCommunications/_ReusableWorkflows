import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from create_prerelease import GitHubAPI, create_prerelease, parse_command  # noqa: E402


HEAD = "a" * 40
REPOSITORY = "SkylineCommunications/Example"
WORKFLOW = "release.yml"
EVENT = {"comment": {"body": "/create-prerelease 1.2.3-internal.4", "user": {"login": "owner"}},
         "issue": {"number": 123, "pull_request": {"url": "https://api.github.com/pr/123"}}}
PR = {"state": "open", "head": {"sha": HEAD, "repo": {"full_name": "fork/Example"}},
      "base": {"repo": {"full_name": REPOSITORY}, "ref": "main"}, "merge_commit_sha": None}


class FakeAPI:
    def __init__(self, token="test-token"):
        self.token = token
        self.pr = PR
        self.permission = "admin"
        self.tag = False
        self.posts = []

    def get(self, path):
        if "/collaborators/" in path:
            return {"permission": self.permission}
        if "/pulls/" in path:
            return self.pr
        if "/git/ref/tags/" in path:
            if self.tag:
                return {"ref": path, "object": {"sha": HEAD}}
            raise LookupError(path)
        if "/contents/" in path:
            return {"type": "file"}
        raise AssertionError(path)

    def post(self, path, data):
        self.posts.append((path, data))
        if path.endswith("/git/refs"):
            self.tag = True
            return {"object": {"sha": data["sha"]}}
        return {}


class PrereleaseTests(unittest.TestCase):
    def test_missing_tag_returns_lookup_error(self):
        api = GitHubAPI("test-token")
        path = "/repos/SkylineCommunications/Example/git/ref/tags/1.2.3-internal.4"
        response = io.BytesIO(b'{"message":"Not Found"}')
        with patch("create_prerelease.urlopen", side_effect=HTTPError(path, 404, "Not Found", {}, response)):
            with self.assertRaises(LookupError):
                api.get(path)

    def test_forbidden_comment_exposes_github_reason(self):
        api = GitHubAPI("test-token")
        path = "/repos/SkylineCommunications/Example/issues/123/comments"
        response = io.BytesIO(b'{"message":"Resource not accessible by integration"}')
        with patch("create_prerelease.urlopen", side_effect=HTTPError(path, 403, "Forbidden", {}, response)):
            with self.assertRaisesRegex(PermissionError, "Resource not accessible by integration"):
                api.post(path, {"body": "feedback"})

    def test_ref_creation_422_exposes_rule_violation(self):
        api = GitHubAPI("test-token")
        path = "/repos/SkylineCommunications/Example/git/refs"
        response = io.BytesIO(b'{"message":"Repository rule violations found","errors":[{"message":"Cannot create this tag"}]}')
        with patch("create_prerelease.urlopen", side_effect=HTTPError(path, 422, "Unprocessable", {}, response)):
            with self.assertRaisesRegex(RuntimeError, "Repository rule violations found; Cannot create this tag"):
                api.post(path, {"ref": "refs/tags/1.2.3-internal.4", "sha": HEAD})

    def test_admin_does_not_query_pr_checks(self):
        api = FakeAPI()
        tag_api = FakeAPI()
        original_get = api.get

        def no_checks(path):
            if any(fragment in path for fragment in ("/branches/", "/rules/", "/check-runs", "/statuses")):
                raise AssertionError(f"Unexpected check lookup: {path}")
            return original_get(path)

        api.get = no_checks
        self.assertEqual(create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW),
                         ("1.2.3-internal.4", HEAD))

    def test_http_tag_response(self):
        class Response:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read(self):
                return self.body

        api = GitHubAPI("test-token")
        with patch("create_prerelease.urlopen", return_value=Response(b'{"object":{"sha":"abc"}}')):
            self.assertEqual(api.post("/repos/example/git/refs", {"ref": "refs/tags/1.2.3-internal.4", "sha": "abc"}),
                             {"object": {"sha": "abc"}})

    def test_exact_command_and_version(self):
        self.assertEqual(parse_command(EVENT["comment"]["body"]), "1.2.3-internal.4")
        for body in ("/create-prerelease", "/create-prerelease 1.2.3", "/create-prerelease 01.2.3-internal.4",
                     "/create-prerelease 1.2.3-internal.4\nother", "/create-prerelease 1.2.3-internal.4 --force"):
            with self.subTest(body=body), self.assertRaises(ValueError):
                parse_command(body)

    def test_admin_tags_pr_head_without_explicit_dispatch(self):
        api = FakeAPI()
        tag_api = FakeAPI()
        self.assertEqual(create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW), ("1.2.3-internal.4", HEAD))
        self.assertEqual(api.posts, [])
        self.assertEqual(tag_api.posts, [(f"/repos/{REPOSITORY}/git/refs", {"ref": "refs/tags/1.2.3-internal.4", "sha": HEAD})])

    def test_missing_pat_does_not_create_tag(self):
        api = FakeAPI()
        tag_api = FakeAPI(token="")
        with self.assertRaisesRegex(ValueError, "PRERELEASE_TAG_TOKEN is required"):
            create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW)
        self.assertEqual(tag_api.posts, [])

    def test_rejects_non_admin_and_invalid_pr(self):
        api = FakeAPI()
        tag_api = FakeAPI()
        api.permission = "write"
        with self.assertRaises(ValueError):
            create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW)
        api.permission = "admin"
        api.pr = {**PR, "head": {**PR["head"], "repo": {"full_name": REPOSITORY}}}
        with self.assertRaises(ValueError):
            create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW)
        self.assertEqual(tag_api.posts, [])

    def test_rejects_closed_pr_and_issue_comment(self):
        api = FakeAPI()
        tag_api = FakeAPI()
        api.pr = {**PR, "state": "closed"}
        with self.assertRaisesRegex(ValueError, "open PR"):
            create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW)
        issue = {**EVENT, "issue": {"number": 123}}
        with self.assertRaisesRegex(ValueError, "pull request"):
            create_prerelease(api, tag_api, issue, REPOSITORY, WORKFLOW)
        self.assertEqual(tag_api.posts, [])

    def test_rejects_existing_tag(self):
        api = FakeAPI()
        tag_api = FakeAPI()
        api.tag = True
        with self.assertRaisesRegex(ValueError, "already exists"):
            create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW)
        self.assertEqual(tag_api.posts, [])

    def test_rejects_head_change_before_tagging(self):
        api = FakeAPI()
        tag_api = FakeAPI()
        original_get = api.get
        calls = 0

        def changed_get(path):
            nonlocal calls
            if "/pulls/" in path:
                calls += 1
                if calls == 2:
                    return {**PR, "head": {**PR["head"], "sha": "b" * 40}}
            return original_get(path)

        api.get = changed_get
        with self.assertRaisesRegex(ValueError, "head changed"):
            create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW)
        self.assertEqual(tag_api.posts, [])

    def test_tag_response_must_match_approved_head(self):
        api = FakeAPI()
        tag_api = FakeAPI()
        original_post = tag_api.post

        def mismatched_post(path, data):
            original_post(path, data)
            return {"object": {"sha": "b" * 40}}

        tag_api.post = mismatched_post
        with self.assertRaisesRegex(ValueError, "approved PR head"):
            create_prerelease(api, tag_api, EVENT, REPOSITORY, WORKFLOW)
        self.assertEqual(len(tag_api.posts), 1)


if __name__ == "__main__":
    unittest.main()