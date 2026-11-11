"""Run the packaged RunApplication API with a new executable chosen by the user.

Usage: python verify_appimage_application.py /path/to/Hiddify.AppImage
Requires the same mTLS client tools as verify_appimage_browser.py.
"""

import argparse
import json
from pathlib import Path
import socket
import tempfile

from verify_appimage_browser import contract, packaged_core


def check(image, directory):
    source = directory / "chosen files"
    source.mkdir()
    sibling = source / "host-only"
    sibling.write_text("host-only")
    selected = source / "my offline client"
    selected.write_text(
        "#!/usr/bin/python3\n"
        "import json, pathlib, socket, sys\n"
        "with socket.socket() as client:\n"
        "    client.settimeout(2)\n"
        "    reachable = client.connect_ex(('127.0.0.1', int(sys.argv[1]))) == 0\n"
        "print(json.dumps([reachable, pathlib.Path(sys.argv[2]).exists(), sys.argv[3:]]))\n"
    )
    selected.chmod(0o700)
    arguments = ["two words", "$HOME", "*.txt", ""]
    wire = contract(directory)
    with socket.socket() as listener, packaged_core(image, directory) as channel:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        address = listener.getsockname()
        with socket.create_connection(address, timeout=2), listener.accept()[0]:
            pass
        run = channel.unary_stream("/hcore.Core/RunApplication",
                                   wire.SandboxRunRequest.SerializeToString,
                                   wire.SandboxEvent.FromString)
        events = list(run(wire.SandboxRunRequest(
            command=[str(selected), str(address[1]), str(sibling), *arguments],
            application_id="generic-appimage-test"), timeout=30))
        states = [event.state for event in events]
        assert wire.SandboxEvent.OFFLINE in states and wire.SandboxEvent.ONLINE not in states, states
        assert states[-1] == wire.SandboxEvent.EXITED and events[-1].exit_code == 0, states
        result = json.loads(b"".join(event.stdout for event in events))
        assert result == [False, False, arguments], result
        listener.setblocking(False)
        try:
            unexpected, _ = listener.accept()
        except BlockingIOError:
            pass
        else:
            unexpected.close()
            raise AssertionError("the offline application connected to the host")
    print("PASS: selected file ran with exact argv, private filesystem and offline network")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    image = parser.parse_args().image.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="hiddify-application-") as scratch:
        check(image, Path(scratch))
