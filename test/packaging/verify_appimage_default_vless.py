"""Exercise the packaged RunApplication lease under Flutter's stock DNS and Clash settings.

Run inside a private Linux network namespace with only loopback, using an ordinary
UID and the same grpcio-tools dependency as verify_appimage_application.py.
The loopback-only Reality echo fixture comes from the pinned core's tests. It
answers TCP and DNS itself. The application must never reach the parent's listener.
"""

import argparse
import base64
import contextlib
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import grpc
from google.protobuf.empty_pb2 import Empty

from verify_appimage_browser import contract, packaged_core


PROBE = """#!/usr/bin/python3
import json, os, socket, struct, sys, time, uuid
instance = str(uuid.uuid4())
token = sys.argv[2]
seq = 0
while True:
    with socket.socket() as sock:
        sock.settimeout(0.25)
        try:
            reached = sock.connect_ex(('127.0.0.1', int(sys.argv[1]))) == 0
        except TimeoutError:
            reached = False
    echo = dns = False
    try:
        data = (token + '-' + str(seq)).encode()
        frame = struct.pack('!H', len(data)) + data
        with socket.create_connection(('198.51.100.44', 443), timeout=1) as peer:
            peer.sendall(frame)
            with peer.makefile('rb') as incoming:
                echo = incoming.read(len(frame)) == frame
        if echo:
            name = str(seq) + '.' + token + '.test.'
            addresses = socket.getaddrinfo(name, None, socket.AF_INET)
            dns = any(entry[4][0] == '198.51.100.44' for entry in addresses)
    except OSError:
        pass
    print(json.dumps([instance, os.getpid(), seq, reached, echo, dns]), flush=True)
    seq += 1
    time.sleep(0.2)
"""


class Application:
    def __init__(self, stream, wire):
        self.stream = stream
        self.wire = wire
        self.queue = queue.Queue()
        self.state = None
        self.pending_output = b""
        self.identity = None
        self.last_seq = -1
        threading.Thread(target=self._receive, daemon=True).start()

    def _receive(self):
        try:
            for event in self.stream:
                self.queue.put(event)
        except grpc.RpcError as error:
            self.queue.put(error)
        finally:
            self.queue.put(None)

    def verify(self, wanted, phase, forbidden=None):
        deadline = time.monotonic() + 18
        count = 0
        while count < 3:
            try:
                event = self.queue.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                raise AssertionError(f"{phase}: expected {wanted}, last network state {self.state}") from None
            if time.monotonic() >= deadline:
                raise AssertionError(f"{phase}: expected {wanted}, last network state {self.state}")
            if isinstance(event, grpc.RpcError):
                raise RuntimeError(f"{phase}: RunApplication returned {event.code()}") from event
            if event is None or event.state in (self.wire.ERROR, self.wire.EXITED):
                raise AssertionError(f"{phase}: application terminated")
            if event.state in (self.wire.OFFLINE, self.wire.ONLINE):
                self.state = self.wire.State.Name(event.state)
                assert self.state != forbidden, f"{phase}: unexpectedly granted {self.state}"
                count = 0
            self.pending_output += event.stdout
            while b"\n" in self.pending_output:
                line, self.pending_output = self.pending_output.split(b"\n", 1)
                instance, pid, seq, direct, echo, dns = json.loads(line)
                if self.identity is None:
                    self.identity = (instance, pid)
                assert (instance, pid) == self.identity and seq > self.last_seq, f"{phase}: program restarted"
                assert not direct, f"{phase}: direct connection reached the parent"
                if forbidden == "ONLINE":
                    assert not echo and not dns, f"{phase}: proxy delivered application traffic"
                self.last_seq = seq
                if self.state == wanted and echo == (wanted == "ONLINE") and dns == echo:
                    count += 1


@contextlib.contextmanager
def reality_server(executable, token):
    ready = queue.Queue()
    echo, dns = threading.Event(), threading.Event()
    with subprocess.Popen([executable, "-flow", "xtls-rprx-vision"], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, text=True) as server:
        def read():
            try:
                for line in server.stdout:
                    event = json.loads(line)
                    if event["kind"] == "ready":
                        ready.put(event["outbound"])
                    elif event["kind"] == "traffic" and event["network"] == "tcp":
                        payload = base64.b64decode(event["payload"])
                        if event["destination"] == "198.51.100.44:443" and payload.startswith(token.encode() + b"-"):
                            echo.set()
                        if event["destination"] == "8.8.8.8:53" and token.encode() in payload:
                            dns.set()
            finally:
                ready.put(None)
        threading.Thread(target=read, daemon=True).start()
        try:
            outbound = ready.get(timeout=10)
            assert outbound, "local VLESS/Reality fixture failed to start"
            yield outbound, echo, dns
        finally:
            server.stdin.close()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()


def check(image, directory, fixture):
    assert os.getuid() != 0, "use an ordinary UID"
    assert {name for _, name in socket.if_nameindex()} == {"lo"}, "run in a loopback-only network namespace"
    sys.path.insert(0, str(Path(__file__).parent / "fixtures"))
    profile = grpc.protos("isolated_profile.proto")
    wire = contract(directory)
    probe = directory / "network client"
    probe.write_text(PROBE)
    probe.chmod(0o700)
    token = uuid.uuid4().hex
    with (socket.socket() as canary, reality_server(fixture, token) as (outbound, observed_echo, observed_dns),
          packaged_core(image, directory) as channel):
        canary.bind(("127.0.0.1", 0))
        canary.listen()
        with socket.create_connection(canary.getsockname(), timeout=2), canary.accept()[0]:
            pass

        def rpc(name, request):
            method = channel.unary_unary("/hcore.Core/" + name, type(request).SerializeToString,
                                         profile.CoreInfoResponse.FromString)
            result = method(request, timeout=30)
            assert result.message_type == 0, f"{name}: core message type {result.message_type}"

        def wait_core(expected):
            states = channel.unary_stream("/hcore.Core/CoreInfoListener", Empty.SerializeToString,
                                          profile.CoreInfoResponse.FromString)(Empty(), timeout=20)
            try:
                for change in states:
                    assert change.message_type == 0, f"core message type {change.message_type}"
                    if change.core_state in expected:
                        return
            finally:
                states.cancel()
            raise AssertionError("core ended its status stream")

        def start(content, raw=False):
            rpc("StartService", profile.StartRequest(config_content=content, config_name="local fixture",
                                                    disable_memory_limit=True, enable_raw_config=raw))
            status = profile.CoreInfoResponse
            wait_core((status.STARTED, status.WAITING, status.NO_AVAILABLE_PROXIES))

        def stop():
            rpc("Stop", Empty())
            wait_core((profile.CoreInfoResponse.STOPPED,))

        # The native defaults differ from the historical Flutter defaults. Supply exactly the
        # values Flutter sends, even when the account has never opened its settings page.
        settings = {"enable-clash-api": True, "remote-dns-address": "tcp://8.8.8.8",
                    "enable-tun": False, "set-system-proxy": False}
        rpc("ChangeHiddifySettings", profile.ChangeHiddifySettingsRequest(hiddify_settings_json=json.dumps(settings)))
        # StartService consumes the normalized profile file produced by the import path.
        vless = json.dumps({"outbounds": [outbound]})
        direct = {"type": "direct", "tag": "only-direct"}
        direct_only = json.dumps({"outbounds": [direct], "route": {"final": direct["tag"]}})
        selectable = json.dumps({
            "experimental": {"clash_api": {"external_controller": "127.0.0.1:0", "secret": token}},
            "outbounds": [{"type": "selector", "tag": "choice", "outbounds": [outbound["tag"], direct["tag"]],
                           "default": outbound["tag"]}, outbound, direct],
            "route": {"final": "choice"},
        })
        run = channel.unary_stream("/hcore.Core/RunApplication", wire.SandboxRunRequest.SerializeToString,
                                   wire.SandboxEvent.FromString)
        stream = run(wire.SandboxRunRequest(command=[str(probe), str(canary.getsockname()[1]), token],
                                            application_id="profile-lease-test"), timeout=180)
        app = Application(stream, wire.SandboxEvent)
        try:
            app.verify("OFFLINE", "no active profile", forbidden="ONLINE")
            start(vless)
            app.verify("ONLINE", "single VLESS/Reality with default Clash API and tcp:// DNS")
            assert observed_echo.wait(2), "VLESS server did not echo this application's TCP payload"
            assert observed_dns.wait(2), "VLESS server did not see this application's DNS over TCP"
            stop()
            app.verify("OFFLINE", "disconnected")
            start(direct_only, raw=True)
            app.verify("OFFLINE", "DIRECT profile", forbidden="ONLINE")
            stop()
            start(selectable, raw=True)
            app.verify("OFFLINE", "external selector can switch to DIRECT", forbidden="ONLINE")
            stop()
            start(vless)
            app.verify("ONLINE", "VLESS/Reality reconnected")
        finally:
            stream.cancel()
        canary.setblocking(False)
        try:
            unexpected, _ = canary.accept()
        except BlockingIOError:
            pass
        else:
            unexpected.close()
            raise AssertionError("the parent received a direct connection")
        print("PASS: same application, confirmed VLESS TCP and DNS, stop/DIRECT offline, restored VLESS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="isolated-profile-") as scratch:
        check(args.image.resolve(strict=True), Path(scratch), args.fixture.resolve(strict=True))
