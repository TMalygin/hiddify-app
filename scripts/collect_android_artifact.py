"""Collect the arm64 APK only after checking its required native libraries."""

from pathlib import Path
import shutil
import sys
from zipfile import BadZipFile, ZipFile


def main():
    apk = Path("build/app/outputs/flutter-apk/app-arm64-v8a-release.apk")
    if not apk.is_file():
        sys.exit(f"Missing requested Android APK: {apk}")

    try:
        with ZipFile(apk) as archive:
            for library in ("libapp.so", "libflutter.so", "libhiddify-core.so"):
                name = f"lib/arm64-v8a/{library}"
                try:
                    entry = archive.getinfo(name)
                except KeyError:
                    sys.exit(f"Incomplete Android APK: missing {name}")
                if entry.file_size == 0:
                    sys.exit(f"Incomplete Android APK: empty {name}")
    except BadZipFile as error:
        sys.exit(f"Invalid Android APK: {error}")

    shutil.copy2(apk, Path("artifacts") / apk.name)


if __name__ == "__main__":
    main()
