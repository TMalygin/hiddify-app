"""Usage: python verify_appimage_browser.py /absolute/path/to/Hiddify.AppImage

Requires Linux x86_64 with rootless user namespaces, bubblewrap, installed Chrome
at /opt/google/chrome/chrome, openssl, and grpcio-tools (tested with 1.85.1).
"""

import argparse
import base64
import contextlib
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import os
from pathlib import Path
import platform
import queue
import secrets
import socket
import subprocess
import tempfile
import threading
from urllib.parse import quote

import grpc
from google.protobuf.wrappers_pb2 import StringValue
from grpc_tools import protoc


def contract(directory):
    schema = Path(__file__).parent / "fixtures/browser_smoke.proto"
    if protoc.main(["protoc", f"-I{schema.parent}", f"--python_out={directory}", str(schema)]):
        raise RuntimeError("could not compile test protobuf schema")
    spec = importlib.util.spec_from_file_location("browser_smoke_pb2", directory / "browser_smoke_pb2.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextlib.contextmanager
def packaged_core(image, directory):
    identity = directory / "grpc"
    identity.mkdir(mode=0o700)
    (directory / "data").mkdir(mode=0o700)
    cert, key = identity / "client.crt", identity / "client.key"
    env = {"PATH": "/usr/bin:/bin", "HOME": str(directory), "TMPDIR": str(directory),
           "APPIMAGE_EXTRACT_AND_RUN": "1", "HIDDIFY_CORE_SECRET": secrets.token_hex(32)}
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=appimage-smoke", "-addext", "extendedKeyUsage=clientAuth",
                    "-keyout", str(key), "-out", str(cert)], env=env, capture_output=True, check=True)
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        address = f"127.0.0.1:{reserved.getsockname()[1]}"
    with subprocess.Popen([str(image), "HiddifyCli", "core", "--mode", "1", "--listen", address,
                           "--base-dir", str(directory), "--working-dir", str(directory),
                           "--temp-dir", str(directory), "--owner-pid", str(os.getpid())],
                          cwd=directory, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as proc:
        try:
            ready = queue.Queue()

            def read_certificate():
                for line in proc.stdout:
                    if line.startswith(b"HIDDIFY_CORE_READY "):
                        ready.put(line.removeprefix(b"HIDDIFY_CORE_READY ").strip())
                        return
                ready.put(None)

            threading.Thread(target=read_certificate, daemon=True).start()
            encoded = ready.get(timeout=90)
            if not encoded:
                raise RuntimeError("packaged HiddifyCli exited before its mTLS readiness message")
            server = base64.b64decode(encoded, validate=True)
            credentials = grpc.ssl_channel_credentials(server, key.read_bytes(), cert.read_bytes())
            with grpc.secure_channel(address, credentials, options=[("grpc.enable_http_proxy", 0)]) as channel:
                # SayHello has one string field in each message, on the same wire tag as StringValue.
                hello = channel.unary_unary("/hello.Hello/SayHello", StringValue.SerializeToString,
                                            StringValue.FromString)
                if hello(StringValue(value="artifact-smoke"), timeout=10).value != "Hello, artifact-smoke":
                    raise AssertionError("unexpected reply to authenticated Hello")
                print("PASS: mTLS Hello from the packaged core", flush=True)
                yield channel
        finally:
            proc.stdin.close()  # The production core monitors this pipe for its parent's lifetime.
            try:
                proc.wait(timeout=18)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
                raise RuntimeError("packaged core did not stop after its parent pipe closed")


def verify(channel, wire):
    launch = channel.unary_stream("/hcore.Core/RunSandbox", wire.SandboxRunRequest.SerializeToString,
                                  wire.SandboxEvent.FromString)

    def run(request):
        events = list(launch(request, timeout=45))
        states = [e.state for e in events]
        output = b"".join(e.stdout for e in events)
        exits = [e.exit_code for e in events if e.state == wire.SandboxEvent.EXITED]
        if exits != [0] or not states or states[-1] != wire.SandboxEvent.EXITED:
            errors = b"".join(e.stderr for e in events)[-800:].decode(errors="replace")
            raise AssertionError(f"app did not exit successfully: {exits=}, {states=}, {errors}")
        if wire.SandboxEvent.OFFLINE not in states or wire.SandboxEvent.ONLINE in states:
            raise AssertionError(f"the child without a profile must stay offline: {states}")
        return output

    run(wire.SandboxRunRequest(command=["/usr/bin/true"]))
    print("PASS: legacy console command with chromium_sandbox off", flush=True)

    def browser(url):
        return run(wire.SandboxRunRequest(
            command=["/opt/google/chrome/chrome", "--headless=new", "--no-first-run",
                     "--no-default-browser-check", "--disable-background-networking", "--dump-dom", url],
            application_id="appimage-smoke", executable_root="/opt/google/chrome", chromium_sandbox=True))

    page = "<title>initial</title><script>document.title=['renderer','executed'].join('-')</script>"
    if b"<title>renderer-executed</title>" not in browser("data:text/html," + quote(page, safe="")):
        raise AssertionError("packaged core did not run the Chromium JavaScript renderer")
    print("PASS: Chrome rendered JavaScript via authenticated RunSandbox", flush=True)

    version = run(wire.SandboxRunRequest(command=["/opt/google/chrome/chrome", "--version"],
                                         application_id="chrome-version", executable_root="/opt/google/chrome"))
    if b"Chrome" not in version:
        raise AssertionError(f"Chrome --version failed with chromium_sandbox off: {version!r}")

    hits = []
    connections = []

    class Listener(ThreadingHTTPServer):
        def get_request(self):
            client, address = super().get_request()
            connections.append(address)
            return client, address

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            hits.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"<title>host-only-response</title>")

        def log_message(self, *args):
            pass

    with Listener(("127.0.0.1", 0), Handler) as server:
        listener = threading.Thread(target=server.serve_forever, daemon=True)
        listener.start()
        try:
            with contextlib.closing(HTTPConnection("127.0.0.1", server.server_port, timeout=5)) as client:
                client.request("GET", "/control")
                if client.getresponse().read() != b"<title>host-only-response</title>" or hits != ["/control"]:
                    raise AssertionError("host HTTP control failed")
            connections.clear()
            hits.clear()
            output = browser(f"http://127.0.0.1:{server.server_port}/host-only")
        finally:
            server.shutdown()
            listener.join(2)
        if connections or hits or b"<title>host-only-response</title>" in output:
            raise AssertionError(f"offline browser reached the host listener: {connections}, {hits}")
    print("PASS: offline Chrome could not reach the host HTTP listener", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    image = parser.parse_args().image.resolve(strict=True)
    if (platform.system() != "Linux" or platform.machine() != "x86_64"
            or os.geteuid() == 0 or os.getuid() != os.geteuid()):
        parser.error("run as an ordinary Linux x86_64 user")
    if not image.is_file() or not os.access(image, os.X_OK):
        parser.error("an executable AppImage is required")
    with tempfile.TemporaryDirectory(prefix="hiddify-browser-smoke-") as temp:
        directory = Path(temp)
        wire = contract(directory)
        with packaged_core(image, directory) as channel:
            verify(channel, wire)
