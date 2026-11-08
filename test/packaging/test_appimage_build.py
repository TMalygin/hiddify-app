"""Run the actual Makefile packaging target with disposable build-tool stubs."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ORIGINAL = b"#!/usr/bin/env python3\n"


class AppImageBuildTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "workspace with spaces"
        self.root.mkdir()
        for name in ("Makefile", "dependencies.properties"):
            shutil.copyfile(ROOT / name, self.root / name)
        shutil.copytree(ROOT / "linux/packaging/appimage", self.root / "linux/packaging/appimage")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.dist = self.root / "dist/5.5.5"
        self.dist.mkdir(parents=True)
        self.image = self.dist / "original.AppImage"
        self.executable(self.image, """#!/usr/bin/env python3
import os, sys
from pathlib import Path
if os.environ.get('FAIL_STEP') == 'extract':
    sys.exit(7)
root = Path('squashfs-root')
(root / 'usr/lib').mkdir(parents=True, exist_ok=True)
(root / 'usr/lib/libstdc++.so.6').write_text('bundled libstdc++')
(root / 'hiddify.desktop').write_text('[Desktop Entry]\\nName=Hiddify\\n')
(root / 'AppRun').write_text('old launcher')
""")
        self.original = self.image.read_bytes()
        self.record = self.root / "packager.json"
        self.executable(self.bin / "fastforge", "#!/bin/sh\nexit 0\n")
        self.executable(self.bin / "appimagetool", """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
source = Path(sys.argv[-2])
if not (source / 'AppRun').is_file():
    sys.exit(9)
Path(os.environ['PACKAGER_RECORD']).write_text(json.dumps({
    'launcher': (source / 'AppRun').read_text(),
    'desktop': (source / 'hiddify.desktop').read_text(),
    'bundled_cpp': (source / 'usr/lib/libstdc++.so.6').exists(),
    'stale_marker': (source / 'stale-marker').exists(),
}))
if os.environ.get('FAIL_STEP') == 'pack':
    sys.exit(13)
output = Path(sys.argv[-1])
output.write_bytes(b'rebuilt AppImage\\n')
output.chmod(0o755)
""")
        for tool, failure in (("cp", "copy"), ("chmod", "permissions"), ("tar", "archive")):
            executable = shutil.which(tool)
            self.assertIsNotNone(executable)
            self.executable(self.bin / tool, "#!/usr/bin/env python3\nimport os,sys\n"
                            f"if os.environ.get('FAIL_STEP') == {failure!r}: sys.exit(17)\n"
                            f"os.execv({executable!r}, [{tool!r}, *sys.argv[1:]])\n")
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        PACKAGER_RECORD=str(self.record))

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def build(self, failure=""):
        return subprocess.run(["make", "linux-appimage-release"], cwd=self.root,
                              env=dict(self.env, FAIL_STEP=failure),
                              capture_output=True, text=True, timeout=20)

    def assert_input_retained(self):
        self.assertTrue(self.image.exists(), "Input AppImage was deleted on failure")
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_failed_extraction_cannot_repackage_stale_output(self):
        stale = self.dist / "squashfs-root"
        (stale / "usr/lib").mkdir(parents=True)
        (stale / "AppRun").write_text("stale launcher")
        (stale / "hiddify.desktop").write_text("[Desktop Entry]\nName=Stale\n")
        (stale / "stale-marker").touch()
        result = self.build("extract")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.record.exists(), "Packager ran after failed extraction")
        self.assert_input_retained()

    def test_failed_launcher_copy_aborts_before_packaging(self):
        result = self.build("copy")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.record.exists())
        self.assert_input_retained()

    def test_failed_permissions_abort_before_packaging(self):
        result = self.build("permissions")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.record.exists())
        self.assert_input_retained()

    def test_failed_packaging_keeps_input(self):
        result = self.build("pack")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_input_retained()

    def test_failed_portable_archive_keeps_input(self):
        result = self.build("archive")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_input_retained()

    def test_multiple_version_outputs_are_rejected_without_deleting_input(self):
        other = self.root / "dist/old"
        other.mkdir()
        shutil.copyfile(self.image, other / "other.AppImage")
        result = self.build()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.record.exists())
        self.assert_input_retained()

    def test_successful_build_contains_current_launcher_and_portable_home(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertEqual(record["launcher"], (ROOT / "linux/packaging/appimage/AppRun").read_text())
        self.assertIn("StartupWMClass=app.hiddify.com", record["desktop"])
        self.assertFalse(record["bundled_cpp"])
        self.assertFalse(record["stale_marker"])
        self.assertEqual((self.dist / "Hiddify.AppImage").read_bytes(), b"rebuilt AppImage\n")
        with tarfile.open(self.dist / "hiddify-linux-appimage.tar.gz") as archive:
            self.assertIn("hiddify-linux-appimage/Hiddify.AppImage.home", archive.getnames())
            self.assertEqual(archive.extractfile("hiddify-linux-appimage/Hiddify.AppImage").read(),
                             b"rebuilt AppImage\n")


if __name__ == "__main__":
    unittest.main()
