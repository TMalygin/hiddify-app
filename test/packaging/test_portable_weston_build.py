"""Run against the release input cache to verify offline display packaging.

Set HIDDIFY_WESTON_PACKAGE_CACHE to the directory containing the pinned inputs.
The test changes a named input from the lock in a private copy of that cache.
No installed Weston or network connection is required by this test.
"""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def input_names(value):
    if isinstance(value, dict):
        if isinstance(value.get('filename'), str):
            yield value['filename']
        for child in value.values():
            yield from input_names(child)
    elif isinstance(value, list):
        for child in value:
            yield from input_names(child)


@unittest.skipUnless(os.environ.get('HIDDIFY_WESTON_PACKAGE_CACHE'), 'requires the pinned source cache')
class PortableWestonBuild(unittest.TestCase):
    def setUp(self):
        self.work = Path(self.enterContext(tempfile.TemporaryDirectory(prefix='portable-weston-build-')))
        self.inputs = Path(os.environ['HIDDIFY_WESTON_PACKAGE_CACHE']).resolve(strict=True)
        self.output = self.work / 'hiddify-weston-runtime.tar.gz'
        self.script = ROOT / 'scripts/linux/prepare_weston_runtime.py'
        self.lock = ROOT / 'scripts/linux/weston-runtime.lock.json'

    def build(self, cache):
        return subprocess.run([sys.executable, self.script, '--cache', cache, '--output', self.output, '--offline'],
                              cwd=self.work, capture_output=True, text=True, timeout=180)

    def test_verified_cache_builds_the_locked_runnable_runtime(self):
        run = self.build(self.inputs)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        manifest = json.loads(self.lock.read_text())
        with gzip.open(self.output, 'rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        self.assertEqual(actual, manifest['tar_sha256'])
        with tarfile.open(self.output, 'r:gz') as archive:
            weston = next((entry for entry in archive if entry.isfile() and Path(entry.name).name == 'weston'), None)
            self.assertIsNotNone(weston, 'runtime contains no Weston executable')
            with archive.extractfile(weston) as stream:
                self.assertEqual(stream.read(4), b'\x7fELF')

    def test_changed_source_is_rejected_and_keeps_the_previous_output(self):
        # First build a real usable output, then deliberately supply different
        # bytes for one package. Existing output must not skip input validation.
        ok = self.build(self.inputs)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        with self.output.open('rb') as stream:
            before = hashlib.file_digest(stream, 'sha256').hexdigest()
        altered = self.work / 'changed inputs'
        shutil.copytree(self.inputs, altered, symlinks=True)
        names = set(input_names(json.loads(self.lock.read_text())))
        candidates = []
        for name in names:
            entry = altered / name
            if (not Path(name).is_absolute() and entry.is_file()
                    and entry.resolve().is_relative_to(altered) and not entry.is_symlink()):
                candidates.append(entry)
        self.assertTrue(candidates, 'the lock must identify a cached input by filename')
        target = max(candidates, key=lambda path: path.stat().st_size)
        with target.open('ab') as stream:
            stream.write(b'unauthenticated change')
        failed = self.build(altered)
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        with self.output.open('rb') as stream:
            after = hashlib.file_digest(stream, 'sha256').hexdigest()
        self.assertEqual(after, before)
