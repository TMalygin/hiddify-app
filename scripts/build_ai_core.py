"""Build the pinned fork core, refusing revisions outside its integration branch."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def build(platform):
    workspace = Path.cwd()
    manifest = json.loads((workspace / "core-source.json").read_text())
    commit = manifest["commit"]
    if manifest["branch"] != "ai" or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("core source must pin a full commit from ai")

    output = workspace / "build/ai-core"
    # npm's existing lockfile derives its project name from this directory.
    source = output / "hiddify-core"
    source.mkdir(parents=True, exist_ok=False)
    environment = {**os.environ, "HIDDIFY_BUILD_ID": commit}

    def run(*command, capture=False, env=environment):
        return subprocess.run(command, cwd=source, env=env, check=True, text=True,
                              stdout=subprocess.PIPE if capture else None).stdout

    run("git", "init")
    run("git", "remote", "add", "origin", manifest["repository"])
    run("git", "fetch", "--no-tags", "--filter=blob:none", "origin", "ai")
    try:
        run("git", "merge-base", "--is-ancestor", commit, "FETCH_HEAD")
    except subprocess.CalledProcessError as error:
        raise ValueError(f"Pinned core {commit} does not belong to ai") from error
    run("git", "checkout", "--detach", commit)
    if run("git", "rev-parse", "HEAD", capture=True).strip() != commit:
        raise ValueError("core checkout does not match the source pin")
    run("git", "-c", "url.https://github.com/.insteadOf=git@github.com:",
        "submodule", "update", "--init", "--recursive")
    (source / "bin").mkdir(exist_ok=True)

    if platform == "linux":
        run("make", "cronet-amd64")
        # Use the pinned Cronet toolchain for both regression tests and the library.
        # Parse its key/value file as data; do not evaluate it as shell code.
        native_environment = dict(environment)
        for line in (source / "cronet/cronet.env").read_text().splitlines():
            key, value = line.split("=", 1)
            if key not in {"CC", "CXX", "CGO_LDFLAGS", "QEMU_LD_PREFIX"}:
                raise ValueError(f"Unexpected Cronet environment variable: {key}")
            native_environment[key] = value
        tags = run("make", "-s", "print-TAGS", capture=True).strip()
        run("go", "vet", "-tags", tags, "./v2/...", env=native_environment)
        run("go", "test", "-count=1", "-tags", tags, "-ldflags=-checklinkname=0",
            "./v2/...", env=native_environment)
        # Keep the committed module lock unchanged; prepare runs go mod tidy
        # for every OS, including platforms that this job does not build.
        run("make", "--assume-old=prepare", "MAKE=make --assume-old=prepare", "linux-amd64")
        files = [("bin/HiddifyCli", "hiddify-core/bin/HiddifyCli"),
                 ("bin/lib/hiddify-core.so", "hiddify-core/bin/lib/hiddify-core.so")]
    else:
        run("make", "--assume-old=prepare", "android")
        files = [("bin/hiddify-core.aar", "android/app/libs/hiddify-core.aar")]

    run("git", "diff", "--exit-code", "HEAD", "--")
    submodules = run("git", "submodule", "status", "--recursive", capture=True)
    if any(line and line[0] != " " for line in submodules.splitlines()):
        raise ValueError("core submodules do not match the pinned source")
    for relative, _ in files:
        if not (source / relative).is_file() or (source / relative).stat().st_size == 0:
            raise ValueError(f"Missing or empty core build output: {relative}")
    for relative, destination in files:
        target = workspace / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, target)
    (output / "CORE_SOURCE.json").write_text(json.dumps(
        {**manifest, "submodules": submodules.splitlines()}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("linux", "android"))
    build(parser.parse_args().platform)
