"""Check a relocated AppImage in normal FUSE and extract-and-run modes.

Run on Linux x86_64 as an ordinary user with FUSE, bubblewrap, GTK 4/PyGObject,
Chrome or Brave, Pillow, grpcio-tools and no system Weston. Set
HIDDIFY_TEST_WESTON_PREFIX to a separate trusted parent installation containing
bin/weston, weston-image and weston-screenshooter. Alternatively supply the
reference Manjaro parent archive in HIDDIFY_WESTON_PACKAGE and its detached
signature in HIDDIFY_WESTON_SIGNATURE. Both options operate on a synthetic
desktop, independently of the display runtime inside the AppImage.
Run: python verify_appimage_display.py /path/to/Hiddify.AppImage
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from urllib.parse import quote

import grpc
from grpc_tools import protoc
from PIL import Image
from verify_appimage_browser import contract, packaged_core


PARENT_PACKAGE_SHA256 = '92fe0bfe2cf1ae02105b0e6573f6695c6bbd4637c9a6b20299a6fea8c3d23b4d'
APP_COLOR = (38, 152, 95)
CLIENT = """#!/usr/bin/python3
import os
os.environ['GDK_BACKEND'] = 'wayland'
os.environ['GSK_RENDERER'] = 'cairo'
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import GLib, Gtk
Gtk.init()
window = Gtk.Window()
area = Gtk.DrawingArea()
def paint(area, cr, width, height):
    cr.set_source_rgb(38/255, 152/255, 95/255)
    cr.paint()
area.set_draw_func(paint)
window.set_child(area)
window.set_default_size(400, 300)
window.present()
GLib.MainLoop().run()
"""


def file_hash(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def wait_for(predicate, message):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(message)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def loaded_library(pid):
    pending = [pid]
    seen = set()
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        process = Path('/proc') / str(pid)
        try:
            for line in (process / 'maps').read_text().splitlines():
                columns = line.split(None, 5)
                if len(columns) == 6 and columns[5].endswith('/hiddify-core.so'):
                    return columns[5]
            for children in (process / 'task').glob('*/children'):
                pending.extend(map(int, children.read_text().split()))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue


def filesystem(path):
    # Find the mount actually supplying the mapped library. An environment
    # flag alone does not prove the runtime chose a specific AppImage mode.
    matches = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        mount, filesystem = line.split(' - ', 1)
        location = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), mount.split()[4])
        if os.path.commonpath([path, location]) == location:
            matches.append((len(location), filesystem.split()[0]))
    return max(matches)[1]


class RelocatedDisplay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.geteuid() == 0 or os.uname().machine != 'x86_64':
            raise RuntimeError('run as an ordinary Linux x86_64 user')
        cls.scratch = Path(cls.enterClassContext(tempfile.TemporaryDirectory(prefix='hiddify-display-image-')))
        if os.environ.get('HIDDIFY_TEST_WESTON_PREFIX'):
            cls.parent = Path(os.environ['HIDDIFY_TEST_WESTON_PREFIX']).resolve(strict=True)
        else:
            package = cls.scratch / 'parent.pkg'
            signature = cls.scratch / 'parent.sig'
            shutil.copyfile(os.environ['HIDDIFY_WESTON_PACKAGE'], package)
            shutil.copyfile(os.environ['HIDDIFY_WESTON_SIGNATURE'], signature)
            if file_hash(package) != PARENT_PACKAGE_SHA256:
                raise RuntimeError('incorrect private test parent package')
            subprocess.run(['pacman-key', '--verify', signature, package], capture_output=True, check=True)
            subprocess.run(['bsdtar', '-xf', package, '-C', cls.scratch, 'usr'], check=True)
            cls.parent = cls.scratch / 'usr'
        cls.modules = [next(cls.parent.rglob(name)) for name in ('headless-backend.so', 'kiosk-shell.so')]
        cls.libs = {cls.parent / 'lib', *(p.parent for p in cls.modules),
                    *(p.parent for p in cls.parent.rglob('libweston-*.so*'))}
        cls.image = cls.scratch / 'Moved Applications' / 'Hiddify with spaces.AppImage'
        cls.image.parent.mkdir()
        source = Path(os.environ['HIDDIFY_DISPLAY_TEST_IMAGE']).resolve(strict=True)
        shutil.copy(source, cls.image)
        if file_hash(source) != file_hash(cls.image):
            raise RuntimeError('the moved AppImage differs from its source')
        cls.wire = contract(cls.scratch)
        schema = Path(__file__).parent / 'fixtures/display_smoke.proto'
        if protoc.main(['protoc', f'-I{schema.parent}', f'--python_out={cls.scratch}', str(schema)]):
            raise RuntimeError('could not compile the display request')
        spec = importlib.util.spec_from_file_location('display_smoke_pb2', cls.scratch / 'display_smoke_pb2.py')
        cls.display_wire = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.display_wire)

    def setUp(self):
        self.work = Path(self.enterContext(tempfile.TemporaryDirectory(dir=self.scratch)))
        self.runtime = self.work / 'desktop'
        self.runtime.mkdir(mode=0o700)
        # Only the synthetic parent and its reference clients see these paths.
        self.parent_env = dict(PATH='/usr/bin:/bin', LANG='C.UTF-8', HOME=str(self.work),
                               XDG_RUNTIME_DIR=str(self.runtime), WAYLAND_DISPLAY='fixture',
                               LD_LIBRARY_PATH=':'.join(map(str, sorted(self.libs))),
                               WESTON_MODULE_MAP=';'.join(f'{p.name}={p}' for p in self.modules),
                               WESTON_DATA_DIR=str(self.parent / 'share/weston'))
        log = self.enterContext((self.work / 'parent.log').open('wb'))
        parent = subprocess.Popen([self.parent / 'bin/weston', '--backend=headless', '--renderer=pixman',
                                   '--shell=kiosk', '--width=800', '--height=600', '--socket=fixture',
                                   '--idle-time=0', '--fake-seat', '--debug', '--no-config'],
                                  env=self.parent_env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        self.addCleanup(stop, parent)
        wait_for((self.runtime / 'fixture').is_socket, 'headless parent failed to listen')
        picture = self.work / 'reference.png'
        color = (47, 123, 197)
        Image.new('RGB', (380, 270), color).save(picture)
        viewer = subprocess.Popen([self.parent / 'bin/weston-image', picture], env=self.parent_env,
                                  stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            wait_for(lambda: self.pixel_count(color) > 10000, 'parent display control failed')
        finally:
            stop(viewer)
        wait_for(lambda: self.pixel_count(color) == 0, 'reference image remained on the parent')

    def pixel_count(self, color):
        with tempfile.TemporaryDirectory(dir=self.work) as scratch:
            run = subprocess.run([self.parent / 'bin/weston-screenshooter', '--verbose'], env=self.parent_env,
                                 cwd=scratch, capture_output=True, timeout=4, check=True)
            self.assertNotIn(b'Output capture error', run.stdout + run.stderr)
            with Image.open(next(Path(scratch).glob('*.png'))) as source:
                frame = source.convert('RGB')
        return next((n for n, rgb in frame.getcolors(frame.width * frame.height) if rgb == color), 0)

    def presented_session(self, launch, request, color, filesystem_kind):
        Event = self.wire.SandboxEvent
        stream = launch(request, timeout=60)
        with ThreadPoolExecutor(max_workers=1) as pool:
            terminal = pool.submit(list, stream)
            try:
                def visible():
                    if terminal.done():
                        try:
                            events = terminal.result()
                        except grpc.RpcError as exc:
                            self.fail(f'{filesystem_kind}: {exc.code().name}: {exc.details()}')
                        codes = [e.exit_code for e in events if e.state == Event.EXITED]
                        self.fail(f'window closed before presenting pixels: {codes}')
                    return self.pixel_count(color) > 10000
                wait_for(visible, 'the moved AppImage failed to display the requested client')
            finally:
                stream.cancel()
        wait_for(lambda: self.pixel_count(color) == 0, 'closing the stream left application pixels visible')

    def check_mode(self, fuse):
        self.assertFalse(shutil.which('weston', path='/usr/local/bin:/usr/bin:/bin'),
                         'requires a test system without native Weston')
        for pattern in ('libweston-*.so*', '*/libweston-*.so*', 'weston/kiosk-shell.so', '*/weston/kiosk-shell.so'):
            self.assertFalse(list(Path('/usr/lib').glob(pattern)), 'host compositor libraries must be absent')
        client = self.work / 'ordinary GTK application'
        client.write_text(CLIENT)
        client.chmod(0o700)
        # Reuse the packaged core mTLS fixture. The wrapper supplies only the
        # synthetic display, selects the real runtime mode, and execs the moved file.
        wrapper = self.work / 'run-image'
        pid_file = self.work / 'runtime-pid'
        wrapper.write_text('#!/usr/bin/python3\nimport os, sys\nfrom pathlib import Path\n'
                           f'Path({str(pid_file)!r}).write_text(str(os.getpid()))\n'
                           f'os.environ.update(XDG_RUNTIME_DIR={str(self.runtime)!r}, WAYLAND_DISPLAY="fixture")\n'
                           + ('os.environ.pop("APPIMAGE_EXTRACT_AND_RUN", None)\n' if fuse else '')
                           + f'os.execv({str(self.image)!r}, [{str(self.image)!r}, *sys.argv[1:]])\n')
        wrapper.chmod(0o700)
        with packaged_core(wrapper, self.work) as channel:
            pid = int(pid_file.read_text())
            lib = wait_for(lambda: loaded_library(pid), 'packaged core library not mapped')
            kind = filesystem(lib)
            self.assertEqual(kind.startswith('fuse'), fuse, (lib, kind))
            launch = channel.unary_stream('/hcore.Core/RunApplication', self.display_wire.DisplayRequest.SerializeToString,
                                          self.wire.SandboxEvent.FromString)
            Request = self.display_wire.DisplayRequest
            Event = self.wire.SandboxEvent
            control = list(launch(Request(command=['/usr/bin/true'], application_id='control'), timeout=20))
            self.assertEqual([e.exit_code for e in control if e.state == Event.EXITED], [0])
            with self.subTest(client='caller-selected GTK executable'):
                req = Request(command=[str(client)], application_id='portable-window', private_wayland=True)
                self.presented_session(launch, req, APP_COLOR, kind)
            with self.subTest(client='installed Chromium browser'):
                chrome = '/opt/google/chrome/chrome'
                brave = '/usr/lib/brave-browser/brave'
                program = brave if Path(brave).is_file() else chrome
                self.assertTrue(Path(program).is_file(), 'the display smoke requires installed Brave or Chrome')
                color = (188, 51, 104)
                page = 'data:text/html,' + quote('<style>html{background:#bc3368}</style>', safe='')
                cmd = [program, '--no-first-run', '--no-default-browser-check', '--disable-background-networking', page]
                req = Request(command=cmd, application_id='portable-browser', private_wayland=True,
                              chromium_sandbox=True, executable_root=str(Path(chrome).parent) if program == chrome else '')
                browser = channel.unary_stream('/hcore.Core/RunSandbox', Request.SerializeToString, Event.FromString)
                self.presented_session(browser, req, color, kind)

    def test_normal_fuse(self):
        self.check_mode(fuse=True)

    def test_extract_and_run(self):
        self.check_mode(fuse=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    args = parser.parse_args()
    os.environ['HIDDIFY_DISPLAY_TEST_IMAGE'] = str(args.image.resolve(strict=True))
    unittest.main(argv=[__file__], verbosity=2)
