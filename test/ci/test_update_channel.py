"""Ensure both ai artifacts compile the fork update channel, not upstream."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "TMalygin/hiddify-app"


class UpdateChannelBuildTest(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.load((ROOT / ".github/workflows/ai.yml").read_text(), Loader=yaml.BaseLoader)
        self.environment = {**os.environ, **self.workflow.get("env", {})}
        self.steps = self.workflow["jobs"]["build"]["steps"]

    def test_android_build_passes_the_fork_channel_to_flutter(self):
        step = next(step for step in self.steps if step.get("name") == "Build Android APK")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            flutter = root / "flutter"
            flutter.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                               "open(os.environ['CAPTURE_ARGS'], 'w').write(json.dumps(sys.argv[1:]))\n")
            flutter.chmod(0o755)
            capture = root / "arguments.json"
            env = {**self.environment, **step.get("env", {}),
                   "PATH": f"{root}:{os.environ['PATH']}", "CAPTURE_ARGS": str(capture)}
            result = subprocess.run(["bash", "-e", "-c", step["run"]], env=env,
                                    cwd=ROOT, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"--dart-define=update_repository={REPOSITORY}", json.loads(capture.read_text()))

    def test_appimage_build_passes_the_fork_channel_to_fastforge(self):
        step = next(step for step in self.steps if step.get("name") == "Build AppImage")
        env = {**self.environment, **step.get("env", {}), "MAKEFLAGS": "--just-print"}
        result = subprocess.run(["bash", "-e", "-c", step["run"]], env=env,
                                cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"--build-dart-define=update_repository={REPOSITORY}", result.stdout)

    def test_ci_runs_behavior_tests_with_the_fork_channel(self):
        commands = "\n".join(step.get("run", "") for step in self.workflow["jobs"]["checks"]["steps"])
        self.assertIn("test/features/app_update/update_channel_test.dart", commands)
        self.assertIn("--dart-define=expect_fork_updates=true", commands)
        self.assertIn(f"--dart-define=update_repository={REPOSITORY}", commands)


if __name__ == "__main__":
    unittest.main()
