"""Check the real embedded runtime's extraction permissions without running Hiddify."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def verify(tool_directory):
    tool = Path(tool_directory).resolve() / "appimagetool"
    with tempfile.TemporaryDirectory(prefix="appimage-runtime-test-") as temporary:
        root = Path(temporary)
        app = root / "probe.AppDir"
        app.mkdir()
        launcher = app / "AppRun"
        launcher.write_text('#!/bin/sh\nstat -c "%a" "$APPDIR"\n')
        launcher.chmod(0o755)
        (app / "probe.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Runtime permission test\n"
            "Exec=AppRun\nIcon=probe\nCategories=Utility;\n")
        (app / "probe.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
            '<rect width="8" height="8"/></svg>')
        image = root / "probe.AppImage"
        environment = {**os.environ, "APPIMAGE_EXTRACT_AND_RUN": "1", "ARCH": "x86_64"}
        subprocess.run([str(tool), "--no-appstream", str(app), str(image)],
                       env=environment, check=True)
        result = subprocess.run([str(image)], env=environment, check=True,
                                capture_output=True, text=True)
        mode = result.stdout.strip()
        assert mode == "700", f"extraction directory must be private (0700), got {mode}"
        print("PASS: the real AppImage runtime extracts into a private 0700 directory")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_appimage_runtime_permissions.py TOOL_DIRECTORY")
    verify(sys.argv[1])
