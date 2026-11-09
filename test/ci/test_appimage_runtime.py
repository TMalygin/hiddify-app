"""Exercise the actual tool-install step and both AppImage packaging callers."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
TOOL_URL = "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
TOOL_SHA = "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
RUNTIME_URL = "https://api.github.com/repos/AppImage/type2-runtime/releases/assets/657374641"
RUNTIME_SHA = "617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46"
RUNTIME = b"fixture runtime, no network\n"
TOOL = b'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['TOOL_RECORD'], 'a') as out:
    out.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ.get('TOOL_EXIT'):
    sys.exit(int(os.environ['TOOL_EXIT']))
Path(sys.argv[-1]).write_bytes(b'fixture AppImage\\n')
'''


class AppImageRuntimeTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "runner with spaces"
        self.root.mkdir()
        self.bin = self.root / "stubs"
        self.bin.mkdir()
        self.path_file = self.root / "github_path"
        self.download_record = self.root / "downloads"
        self.tool_record = self.root / "calls"
        workflow = yaml.load((ROOT / ".github/workflows/ai.yml").read_text(), Loader=yaml.BaseLoader)
        self.step = next(s["run"] for s in workflow["jobs"]["build"]["steps"]
                         if s.get("name") == "Install Linux packaging tools")
        self.executable(self.bin / "sudo", "#!/bin/sh\nexit 0\n")
        self.executable(self.bin / "dart", "#!/bin/sh\nexit 0\n")
        self.executable(self.bin / "curl", """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
url = args[-1]
with open(os.environ['DOWNLOAD_RECORD'], 'a') as out:
    out.write(json.dumps(url) + '\\n')
is_runtime = url == os.environ['RUNTIME_URL']
if is_runtime and os.environ.get('FAIL_RUNTIME'):
    sys.exit(22)
payload = bytes.fromhex(os.environ['RUNTIME_HEX' if is_runtime else 'TOOL_HEX'])
if is_runtime and os.environ.get('CORRUPT_RUNTIME'):
    payload += b'corrupt'
Path(args[args.index('--output') + 1]).write_bytes(payload)
""")
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "RUNNER_TEMP": str(self.root), "GITHUB_PATH": str(self.path_file),
                    "DOWNLOAD_RECORD": str(self.download_record), "TOOL_RECORD": str(self.tool_record),
                    "TOOL_HEX": TOOL.hex(), "RUNTIME_HEX": RUNTIME.hex(), "RUNTIME_URL": RUNTIME_URL}

    @staticmethod
    def executable(path, contents):
        path.write_text(contents)
        path.chmod(0o755)

    def install(self, **extra):
        # Only the disposable command copy uses fixture digests. The separate
        # pin assertion checks the actual workflow's upstream release hashes.
        command = self.step.replace(TOOL_SHA, hashlib.sha256(TOOL).hexdigest())
        command = command.replace(RUNTIME_SHA, hashlib.sha256(RUNTIME).hexdigest())
        return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command],
                              cwd=ROOT, env={**self.env, **extra}, text=True, capture_output=True, timeout=20)

    def ready(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        paths = self.path_file.read_text().splitlines()
        return {**self.env, "PATH": os.pathsep.join([*paths, self.env["PATH"]])}

    def calls(self):
        return [json.loads(line) for line in self.tool_record.read_text().splitlines()]

    def assert_runtime(self, args):
        self.assertIn("--runtime-file", args, "packaging can download an unpinned runtime")
        runtime = Path(args[args.index("--runtime-file") + 1])
        self.assertEqual(runtime.read_bytes(), RUNTIME)
        self.assertEqual(args.count("--runtime-file"), 1)

    def test_versioned_downloads_have_repository_controlled_digests(self):
        for value in (TOOL_URL, TOOL_SHA, RUNTIME_URL, RUNTIME_SHA):
            self.assertIn(value, self.step)
        self.assertNotIn("/continuous/", self.step)

    def test_installs_one_verified_runtime(self):
        self.ready()
        downloads = [json.loads(line) for line in self.download_record.read_text().splitlines()]
        self.assertEqual(downloads, [TOOL_URL, RUNTIME_URL])

    def test_initial_packaging_uses_the_verified_runtime_and_preserves_arguments(self):
        env = self.ready()
        output = self.root / "initial.AppImage"
        args = ["--no-appstream", "fixture AppDir", str(output)]
        result = subprocess.run(["appimagetool", *args], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[-1]
        self.assert_runtime(call)
        self.assertEqual(call[-3:], args)

    def test_repackaging_uses_the_same_verified_runtime(self):
        env = self.ready()
        dist = self.root / "dist/version"
        dist.mkdir(parents=True)
        self.executable(dist / "original.AppImage", """#!/usr/bin/env python3
from pathlib import Path
root = Path('squashfs-root')
(root / 'usr/lib').mkdir(parents=True)
(root / 'hiddify.desktop').write_text('[Desktop Entry]\\nName=Hiddify\\n')
""")
        result = subprocess.run(["bash", str(ROOT / "linux/packaging/appimage/repackage.sh"), str(dist.parent)],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_runtime(self.calls()[-1])
        self.assertTrue((dist / "Hiddify.AppImage").is_file())

    def test_modified_runtime_aborts_installation(self):
        result = self.install(CORRUPT_RUNTIME="1")
        self.assertNotEqual(result.returncode, 0, "corrupt runtime was accepted")
        self.assertFalse(self.path_file.exists(), "unverified toolchain was exposed on PATH")
        self.assertFalse(self.tool_record.exists())

    def test_failed_runtime_download_aborts_installation(self):
        result = self.install(FAIL_RUNTIME="1")
        self.assertNotEqual(result.returncode, 0, "runtime download failure was ignored")
        self.assertFalse(self.path_file.exists())

    def test_caller_cannot_replace_the_verified_runtime(self):
        env = self.ready()
        for override in (["--runtime-file", "/untrusted"], ["--runtime-file=/untrusted"]):
            result = subprocess.run(["appimagetool", *override, "input", str(self.root / "override.AppImage")],
                                    env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0, "caller overrode the pinned runtime")
        self.assertFalse(self.tool_record.exists())

    def test_packager_failure_is_preserved(self):
        env = {**self.ready(), "TOOL_EXIT": "17"}
        result = subprocess.run(["appimagetool", "input", "output"], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 17)


if __name__ == "__main__":
    unittest.main()
