"""Policy checks for the fork's ai validation and artifact workflow."""

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]


class AiWorkflowTest(unittest.TestCase):
    def setUp(self):
        path = ROOT / ".github/workflows/ai.yml"
        self.assertTrue(path.is_file(), "ai has no validation/build workflow")
        self.workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)

    def test_targets_ai_pushes_and_pull_requests(self):
        events = self.workflow["on"]
        self.assertEqual(events["push"]["branches"], ["ai"])
        self.assertEqual(events["pull_request"]["branches"], ["ai"])
        self.assertIn("workflow_dispatch", events)

    def test_checks_cover_python_and_flutter_regressions(self):
        commands = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["checks"]["steps"])
        self.assertIn("unittest discover -s test/packaging", commands)
        self.assertIn("unittest discover -s test/ci", commands)
        self.assertIn("flutter test", commands)

    def test_both_platform_builds_require_checks(self):
        build = self.workflow["jobs"]["build"]
        self.assertIn("checks", build["needs"])
        platforms = {entry["platform"] for entry in build["strategy"]["matrix"]["include"]}
        self.assertEqual(platforms, {"linux", "android"})
        commands = "\n".join(step.get("run", "") for step in build["steps"])
        self.assertIn("make linux-appimage-release", commands)
        self.assertIn("flutter build apk", commands)

    def test_artifacts_are_commit_identified_and_only_published_from_ai(self):
        uploads = [step for job in self.workflow["jobs"].values() for step in job["steps"]
                   if step.get("uses", "").startswith("actions/upload-artifact@")]
        self.assertTrue(uploads)
        for step in uploads:
            self.assertIn("github.ref == 'refs/heads/ai'", step["if"])
            self.assertIn("github.sha", step["with"]["name"])
            self.assertEqual(step["with"]["if-no-files-found"], "error")

    def test_uses_checked_out_commit_without_write_credentials(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        for job in self.workflow["jobs"].values():
            self.assertNotIn("permissions", job)
            checkouts = [s for s in job["steps"] if s.get("uses", "").startswith("actions/checkout@")]
            self.assertEqual(len(checkouts), 1)
            self.assertNotIn("ref", checkouts[0].get("with", {}))
            self.assertEqual(checkouts[0]["with"]["persist-credentials"], "false")

    def test_failures_are_not_ignored_or_published_as_releases(self):
        for job in self.workflow["jobs"].values():
            self.assertNotIn("continue-on-error", job)
            for step in job["steps"]:
                self.assertNotIn("continue-on-error", step)
                self.assertNotIn("softprops/action-gh-release", step.get("uses", ""))
                self.assertNotIn("gh release", step.get("run", ""))


if __name__ == "__main__":
    unittest.main()
