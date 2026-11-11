#!/usr/bin/env python3
"""Build the private Linux display from authenticated Debian snapshot packages, without installing them."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tarfile
import tempfile
from urllib.parse import quote
from urllib.request import urlopen

LOCK = Path(__file__).with_name("weston-runtime.lock.json")


def atomic_write(path, write):
    """Publish only a complete, verified file. Concurrent builders use distinct temporaries."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", delete=False) as output:
        temporary = Path(output.name)
        try:
            write(output)
            output.close()
            os.chmod(temporary, 0o644)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def package_bytes(path, url, size, expected_hash, offline):
    def verified(data):
        return len(data) == size and hashlib.sha256(data).hexdigest() == expected_hash

    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except FileNotFoundError:
        pass
    else:
        with os.fdopen(fd, "rb") as cached:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ValueError(f"Expected a regular cache file for {path.name}")
            data = cached.read(size + 1)
        if verified(data):
            return data
    if offline:
        raise ValueError(f"Missing or damaged package in the offline cache: {path.name}")
    with urlopen(url, timeout=60) as response:
        if not response.geturl().startswith("https://"):
            raise ValueError(f"Expected an HTTPS response for {path.name}")
        data = response.read(size + 1)
    if not verified(data):
        raise ValueError(f"Downloaded package has an unexpected size or SHA-256: {path.name}")
    atomic_write(path, lambda output: output.write(data))
    return data


def checked_path(name):
    path = PurePosixPath(name)
    if not path.parts or path.is_absolute() or "\\" in name or "\x00" in name or ".." in path.parts or str(path) != name:
        raise ValueError(f"Invalid relative tar member: {name}")
    return name


def debian_payload(raw):
    # Debian binary packages use an ar archive. Read only the data tarball;
    # installation scripts, metadata and paths are never executed or extracted.
    if not raw.startswith(b"!<arch>\n"):
        raise ValueError("Invalid Debian binary package")
    offset = 8
    version = None
    payload = None
    while offset < len(raw):
        header = raw[offset:offset + 60]
        if len(header) != 60 or header[58:] != b"`\n":
            raise ValueError("Invalid ar member header")
        name = header[:16].rstrip(b" /")
        size = int(header[48:58])
        offset += 60
        if size < 0 or offset + size > len(raw):
            raise ValueError("Invalid ar member size")
        if name == b"debian-binary":
            version = raw[offset:offset + size]
        elif name in (b"data.tar.xz", b"data.tar.gz", b"data.tar.bz2"):
            if payload is not None:
                raise ValueError("More than one Debian data tarball")
            payload = raw[offset:offset + size]
        offset += size + size % 2
    if offset != len(raw) or version != b"2.0\n" or payload is None:
        raise ValueError("Incomplete Debian binary package")
    return payload


def selected_files(raw, package):
    # Map selected aliases to regular source members while preparing the lock.
    # The capsule therefore contains no symbolic or hard links.
    members = {checked_path(name): name for name in package["files"]}
    for target, source in package.get("aliases", {}).items():
        if target in members:
            raise ValueError(f"Duplicate selected file: {target}")
        members[checked_path(target)] = checked_path(source)
    required = set(members.values())
    found = {}
    with tarfile.open(fileobj=io.BytesIO(debian_payload(raw)), mode="r|*") as archive:
        for info in archive:
            name = info.name.removeprefix("./")
            if name not in required:
                continue
            if not info.isreg() or name in found:
                raise ValueError(f"Expected one regular input file: {name}")
            with archive.extractfile(info) as source:
                found[name] = (0o555 if info.mode & 0o111 else 0o444, source.read())
    if missing := required - found.keys():
        raise ValueError(f"Missing package members: {sorted(missing)}")
    return {target: found[source] for target, source in members.items()}


def write_archive(output, directories, files, lock):
    # Hash the entire canonical USTAR stream including final block padding. The
    # gzip implementation available on a builder need not emit identical bytes.
    digest = hashlib.sha256()
    total = 0
    with gzip.GzipFile(filename="", fileobj=output, mode="wb", compresslevel=6, mtime=0) as compressed:
        class TarStream:
            def write(self, block):
                nonlocal total
                total += len(block)
                digest.update(block)
                return compressed.write(block)

        with tarfile.open(fileobj=TarStream(), mode="w|", format=tarfile.USTAR_FORMAT) as archive:
            for name in sorted(directories | files.keys()):
                info = tarfile.TarInfo(name)  # uid, gid, mtime = 0; uname and gname are empty
                if name in directories:
                    info.type, info.mode = tarfile.DIRTYPE, 0o755
                    archive.addfile(info)
                else:
                    info.mode, data = files[name]
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
    if total != lock["tar_bytes"] or digest.hexdigest() != lock["tar_sha256"]:
        raise ValueError("Assembled Weston runtime does not match the locked USTAR size and SHA-256")


def prepare(output, cache, offline):
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if lock["format"] != 1 or not lock["base_url"].startswith("https://"):
        raise ValueError("Unsupported Weston runtime package lock")

    def load(package):
        pool_path = checked_path(package["path"])
        filename = package["filename"]
        if PurePosixPath(pool_path).name != filename:
            raise ValueError(f"Unexpected Debian cache filename: {filename}")
        url = f"{lock['base_url']}/{quote(pool_path)}"
        raw = package_bytes(cache / filename, url, package["bytes"], package["sha256"], offline)
        return selected_files(raw, package)

    files = {}
    with ThreadPoolExecutor(max_workers=4) as workers:
        for selected in workers.map(load, lock["packages"].values()):
            if collisions := files.keys() & selected.keys():
                raise ValueError(f"Multiple packages provide {sorted(collisions)}")
            files.update(selected)
    directories = {checked_path(path) for path in lock["directories"]}
    for name in [*files, *directories]:
        directories.update(str(parent) for parent in PurePosixPath(name).parents if parent.parts)
    if directories & files.keys():
        raise ValueError("A Weston runtime file collides with a directory")
    atomic_write(output, lambda destination: write_archive(destination, directories, files, lock))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Destination .tar.gz file")
    parser.add_argument("--cache", type=Path, required=True, help="Directory for verified Debian .deb files")
    parser.add_argument("--offline", action="store_true", help="Use only previously downloaded packages")
    args = parser.parse_args()
    try:
        prepare(args.output, args.cache, args.offline)
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"Cannot prepare private Weston: {error}\n")
    print(args.output)


if __name__ == "__main__":
    main()
