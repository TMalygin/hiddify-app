"""Exercise the workflow's real collection step against representative APKs."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from zipfile import ZipFile

import yaml


ROOT = Path(__file__).resolve().parents[2]
TARGET = "app-arm64-v8a-release.apk"
LIBRARIES = ("libapp.so", "libflutter.so", "libhiddify-core.so")


class AndroidArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.apks = self.root / "build/app/outputs/flutter-apk"
        self.apks.mkdir(parents=True)
        (self.root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        workflow = yaml.load((ROOT / ".github/workflows/ai.yml").read_text(), Loader=yaml.BaseLoader)
        self.command = next(step["run"] for step in workflow["jobs"]["build"]["steps"]
                            if step.get("name") == "Collect artifacts and checksums")
        self.commit = "1" * 40
        self.write_apk(TARGET, "arm64-v8a", LIBRARIES)
        self.write_apk("app-armeabi-v7a-release.apk", "armeabi-v7a", ("libhiddify-core.so",))
        self.write_apk("app-x86_64-release.apk", "x86_64", ("libhiddify-core.so",))
        self.write_apk("app-release.apk", "arm64-v8a", LIBRARIES)

    def write_apk(self, name, abi, libraries, empty=()):
        with ZipFile(self.apks / name, "w") as archive:
            for library in libraries:
                archive.writestr(f"lib/{abi}/{library}", b"" if library in empty else b"test library")

    def collect(self):
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", self.command], cwd=self.root,
            env={**os.environ, "BUILD_PLATFORM": "android", "GITHUB_SHA": self.commit},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
        )

    def test_only_the_requested_complete_abi_is_published(self):
        result = self.collect()
        self.assertEqual(result.returncode, 0, result.stdout)
        artifacts = self.root / "artifacts"
        self.assertEqual(sorted(p.name for p in artifacts.glob("*.apk")), [TARGET])
        self.assertEqual((artifacts / TARGET).read_bytes(), (self.apks / TARGET).read_bytes())
        self.assertEqual((artifacts / "COMMIT").read_text().strip(), self.commit)
        for line in (artifacts / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(hashlib.sha256((artifacts / name).read_bytes()).hexdigest(), digest)

    def test_missing_target_does_not_fall_back_to_another_apk(self):
        (self.apks / TARGET).unlink()
        result = self.collect()
        self.assertNotEqual(result.returncode, 0, "collection accepted APKs for the wrong ABI")
        self.assertFalse(list((self.root / "artifacts").glob("*.apk")))

    def test_missing_flutter_runtime_is_rejected(self):
        self.write_apk(TARGET, "arm64-v8a", ("libapp.so", "libhiddify-core.so"))
        result = self.collect()
        self.assertNotEqual(result.returncode, 0, "collection accepted an APK without Flutter")
        self.assertIn("libflutter.so", result.stdout)
        self.assertFalse(list((self.root / "artifacts").glob("*.apk")))

    def test_empty_native_library_is_rejected(self):
        self.write_apk(TARGET, "arm64-v8a", LIBRARIES, empty=("libflutter.so",))
        result = self.collect()
        self.assertNotEqual(result.returncode, 0, "collection accepted an empty Flutter library")
        self.assertIn("libflutter.so", result.stdout)
        self.assertFalse(list((self.root / "artifacts").glob("*.apk")))


if __name__ == "__main__":
    unittest.main()
