"""Exercise source pinning and failure handling with a disposable core repository."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
PATCHED_CORE = "1fc80d7868364fc15519267d75add9634f5aed39"


class CoreSourceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.workspace = self.root / "app with spaces"
        self.workspace.mkdir()
        self.core = self.root / "core"
        self.core.mkdir()
        self.git("init", "-b", "ai")
        self.git("config", "user.name", "Regression Test")
        self.git("config", "user.email", "regression@example.invalid")
        (self.core / "Makefile").write_text(
            "cronet-amd64:\n\tmkdir -p cronet\n\tprintf 'CC=cc\\n' > cronet/cronet.env\n"
            "linux-amd64:\n\ttest -z \"$$FAIL_CORE_BUILD\"\n"
            "\tmkdir -p bin/lib\n\tcp payload bin/lib/hiddify-core.so\n\tcp payload bin/HiddifyCli\n"
            "android:\n\ttest -z \"$$FAIL_CORE_BUILD\"\n\tmkdir -p bin\n\tcp payload bin/hiddify-core.aar\n"
            "print-TAGS:\n\t@echo fixture\n"
        )
        (self.core / "payload").write_bytes(b"pinned core bytes\n")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.manifest = {"repository": self.core.as_uri(), "branch": "ai", "commit": self.commit}
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "go").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "go").chmod(0o755)

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.core, text=True, stderr=subprocess.DEVNULL)

    def build(self, platform="linux", **environment):
        (self.workspace / "core-source.json").write_text(json.dumps(self.manifest))
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/build_ai_core.py"), platform], cwd=self.workspace,
            env={**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                 "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow",
                 "GIT_CONFIG_VALUE_0": "always", **environment},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
        )

    def test_workflow_uses_the_patched_fork_source_and_records_it(self):
        path = ROOT / "core-source.json"
        self.assertTrue(path.is_file(), "ai builds still use upstream core without the authentication fix")
        manifest = json.loads(path.read_text())
        self.assertEqual(manifest, {"repository": "https://github.com/TMalygin/hiddify-core.git",
                                    "branch": "ai", "commit": PATCHED_CORE})
        workflow = yaml.load((ROOT / ".github/workflows/ai.yml").read_text(), Loader=yaml.BaseLoader)
        commands = "\n".join(s.get("run", "") for s in workflow["jobs"]["build"]["steps"])
        self.assertIn("python3 scripts/build_ai_core.py", commands)
        self.assertNotIn("hiddify/hiddify-core/releases/download", commands)
        self.assertIn("CORE_SOURCE.json", commands)

    def test_linux_uses_the_pin_even_when_ai_has_advanced(self):
        (self.core / "payload").write_bytes(b"different branch-tip bytes\n")
        self.git("commit", "-am", "advance ai")
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout)
        for relative in ("hiddify-core/bin/HiddifyCli", "hiddify-core/bin/lib/hiddify-core.so"):
            self.assertEqual((self.workspace / relative).read_bytes(), b"pinned core bytes\n")
        source = json.loads((self.workspace / "build/ai-core/CORE_SOURCE.json").read_text())
        for key, value in self.manifest.items():
            self.assertEqual(source[key], value)

    def test_android_stages_the_built_aar(self):
        result = self.build("android")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.workspace / "android/app/libs/hiddify-core.aar").read_bytes(),
                         b"pinned core bytes\n")

    def test_commit_outside_ai_is_rejected_before_build(self):
        self.git("checkout", "-b", "unmerged")
        (self.core / "payload").write_bytes(b"unmerged bytes\n")
        self.git("commit", "-am", "unmerged change")
        self.manifest["commit"] = self.git("rev-parse", "HEAD").strip()
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not belong to ai", result.stdout)
        self.assertFalse((self.workspace / "hiddify-core/bin").exists())
        self.assertFalse((self.workspace / "build/ai-core/CORE_SOURCE.json").exists())

    def test_failed_core_build_cannot_fall_back_to_release_libraries(self):
        result = self.build(FAIL_CORE_BUILD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL_CORE_BUILD", result.stdout)
        self.assertFalse((self.workspace / "hiddify-core/bin").exists())
        self.assertFalse((self.workspace / "build/ai-core/CORE_SOURCE.json").exists())


if __name__ == "__main__":
    unittest.main()
