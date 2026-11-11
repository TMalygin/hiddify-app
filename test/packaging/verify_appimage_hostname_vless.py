"""Check a domain-based Reality profile with a numeric peer verified by the ordinary core.

Run via verify_appimage_hostname_vless.sh in a disposable loopback-only namespace.
Only the ordinary core gets the endpoint name-to-address mapping. A separate
client sends a unique echo through its mixed inbound to establish authentic
traffic on that exact VLESS leaf. The isolated application starts before any
profile and keeps sending its own, distinct TCP and DNS probes throughout.
"""
import base64
import contextlib
import http.client
import json
import os
from pathlib import Path
import queue
import select
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import uuid

import grpc
from google.protobuf.empty_pb2 import Empty

from verify_appimage_browser import contract, packaged_core
from verify_appimage_default_vless import Application, PROBE


DNS_PEER = "192.0.2.53"


class RelayConnection(socketserver.BaseRequestHandler):
    """Make a local Reality endpoint unavailable, then pass its TLS stream intact."""

    def handle(self):
        server = self.server
        if not server.available.is_set():
            return
        with socket.create_connection(server.destination, timeout=5) as upstream:
            server.forwarded.set()
            upstream.settimeout(None)
            peers = {self.request: upstream, upstream: self.request}
            try:
                while peers:
                    readable, _, _ = select.select(list(peers), [], [], 15)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if data:
                            peers[source].sendall(data)
                        else:
                            peers.pop(source).shutdown(socket.SHUT_WR)
            except OSError:
                pass  # Ordinary cleanup and intentionally invalid credentials close the stream.


@contextlib.contextmanager
def reality_node(executable, child_token):
    ready = queue.Queue()
    echo, dns = threading.Event(), threading.Event()
    with subprocess.Popen([executable, "-flow", "xtls-rprx-vision"], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, text=True) as server:
        def observe():
            try:
                for line in server.stdout:
                    event = json.loads(line)
                    if event["kind"] == "ready":
                        ready.put(event["outbound"])
                    elif event["kind"] == "traffic" and event["network"] == "tcp":
                        data = base64.b64decode(event["payload"])
                        if event["destination"] == "198.51.100.44:443" and data.startswith(child_token.encode() + b"-"):
                            echo.set()
                        if event["destination"] == DNS_PEER + ":53" and child_token.encode() in data:
                            dns.set()
            finally:
                ready.put(None)

        observer = threading.Thread(target=observe, daemon=True)
        observer.start()
        try:
            outbound = ready.get(timeout=10)
            assert outbound, "local Reality fixture failed to start"
            yield outbound, echo, dns
        finally:
            server.stdin.close()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
            observer.join(timeout=5)


@contextlib.contextmanager
def endpoint(executable, child_token, address, port=0):
    with reality_node(executable, child_token) as (leaf, echo, dns):
        with socketserver.ThreadingTCPServer((address, port), RelayConnection) as relay:
            relay.daemon_threads = True
            relay.available = threading.Event()
            relay.forwarded = threading.Event()
            relay.destination = (leaf["server"], leaf["server_port"])
            thread = threading.Thread(target=relay.serve_forever, daemon=True)
            thread.start()
            try:
                # The endpoint domain is distinct from the real SNI from the fixture.
                yield dict(leaf, server=uuid.uuid4().hex + ".invalid",
                           server_port=relay.server_address[1]), relay, echo, dns
            finally:
                relay.shutdown()
                thread.join()


def ordinary_echo(mixed_port):
    payload = b"ordinary-" + uuid.uuid4().hex.encode()
    frame = struct.pack("!H", len(payload)) + payload
    connection = http.client.HTTPConnection("127.0.0.1", mixed_port, timeout=4)
    try:
        connection.set_tunnel("198.51.100.44", 443)
        connection.connect()
        connection.sock.sendall(frame)
        with connection.sock.makefile("rb") as reply:
            return reply.read(len(frame)) == frame
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def profile_for(leaf, mixed_port, address):
    mapping = {leaf["server"]: address} if address else {}
    return json.dumps({
        "inbounds": [{"type": "mixed", "tag": "ordinary-client", "listen": "127.0.0.1",
                      "listen_port": mixed_port}],
        "outbounds": [leaf],
        "dns": {"servers": [{"type": "hosts", "tag": "fixture-hosts", "predefined": mapping}]},
        "route": {"final": leaf["tag"], "default_domain_resolver": "fixture-hosts"},
        # Keep the normal core's own startup health check synthetic as well.
        "experimental": {"clash_api": {"external_controller": "127.0.0.1:0"},
                         "monitoring": {"urls": ["http://health.fixture.invalid/"], "interval": "1h",
                                        "url_test_timeout": "1s"}},
    })


def check(image, directory, executable):
    assert os.getuid() != 0 and {name for _, name in socket.if_nameindex()} == {"lo"}
    sys.path.insert(0, str(Path(__file__).parent / "fixtures"))
    api = grpc.protos("isolated_profile.proto")
    wire = contract(directory)
    probe = directory / "network client"
    probe.write_text(PROBE)
    probe.chmod(0o700)
    child = uuid.uuid4().hex
    # Distinct addresses on the same port make reuse of A's peer during B observable.
    with (endpoint(executable, child, "127.0.0.2") as (a, gate_a, echo_a, dns_a),
          endpoint(executable, child, "127.0.0.3", a["server_port"]) as (b, gate_b, echo_b, dns_b),
          socket.socket() as canary, packaged_core(image, directory) as channel):
        canary.bind(("127.0.0.1", 0))
        canary.listen()
        with socket.create_connection(canary.getsockname(), timeout=2), canary.accept()[0]:
            pass
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            mixed_port = reserved.getsockname()[1]

        def rpc(name, request):
            invoke = channel.unary_unary("/hcore.Core/" + name, type(request).SerializeToString,
                                         api.CoreInfoResponse.FromString)
            result = invoke(request, timeout=30)
            assert result.message_type == 0, f"{name}: core error {result.message_type}"

        def await_state(expected):
            states = channel.unary_stream("/hcore.Core/CoreInfoListener", Empty.SerializeToString,
                                          api.CoreInfoResponse.FromString)(Empty(), timeout=30)
            try:
                for event in states:
                    assert event.message_type == 0, f"core error {event.message_type}"
                    if event.core_state in expected:
                        return
            finally:
                states.cancel()
            raise AssertionError("core state stream ended")

        def activate(leaf, endpoint_gate=None, method="StartService"):
            address = endpoint_gate.server_address[0] if endpoint_gate else None
            request = api.StartRequest(config_name="local scenario", config_content=profile_for(leaf, mixed_port, address),
                                       enable_raw_config=True, disable_memory_limit=True)
            rpc(method, request)
            status = api.CoreInfoResponse
            await_state((status.STARTED, status.WAITING, status.NO_AVAILABLE_PROXIES))

        def stop():
            rpc("Stop", Empty())
            await_state((api.CoreInfoResponse.STOPPED,))

        rpc("ChangeHiddifySettings", api.ChangeHiddifySettingsRequest(hiddify_settings_json=json.dumps({
            "remote-dns-address": "tcp://" + DNS_PEER, "enable-clash-api": True,
            "enable-tun": False, "set-system-proxy": False,
        })))
        run = channel.unary_stream("/hcore.Core/RunApplication", wire.SandboxRunRequest.SerializeToString,
                                   wire.SandboxEvent.FromString)
        stream = run(wire.SandboxRunRequest(command=[str(probe), str(canary.getsockname()[1]), child],
                                            application_id="domain-profile-test"), timeout=240)
        app = Application(stream, wire.SandboxEvent)

        def offline(phase):
            app.verify("OFFLINE", phase, forbidden="ONLINE")
            print(f"PASS {phase}: same child offline", flush=True)

        try:
            offline("no profile")
            activate({"type": "direct", "tag": "ordinary-direct"})
            offline("DIRECT")
            stop()
            activate(dict(a, uuid=str(uuid.uuid4())), gate_a)
            gate_a.available.set()
            assert not ordinary_echo(mixed_port), "wrong VLESS UUID returned the ordinary client's payload"
            assert gate_a.forwarded.wait(2), "ordinary connection did not reach the test endpoint"
            offline("Reality reachable with incorrect VLESS UUID")
            assert not echo_a.is_set() and not dns_a.is_set()
            gate_a.available.clear()
            stop()

            activate(a, gate_a)
            assert not ordinary_echo(mixed_port), "the disabled endpoint returned a payload"
            offline("endpoint unavailable")
            gate_a.forwarded.clear()
            gate_a.available.set()
            offline("endpoint available without an authenticated ordinary request")
            assert not gate_a.forwarded.is_set(), "an unsolicited bootstrap reached endpoint A"
            assert not echo_a.is_set() and not dns_a.is_set(), "the child sent traffic before verification"
            assert ordinary_echo(mixed_port), "ordinary core failed to resolve and authenticate endpoint A"
            print("PASS ordinary endpoint A returned a unique payload through the mixed inbound", flush=True)
            app.verify("ONLINE", "ordinary endpoint A authenticated; child TCP and DNS through A")
            assert echo_a.wait(2) and dns_a.wait(2), "A did not observe the child's distinct TCP and DNS"

            activate(b, gate_b, "Restart")
            app.verify("OFFLINE", "switch A to unreachable B")
            offline("B has no peer and cannot reuse A")
            echo_a.clear()
            dns_a.clear()
            gate_b.available.set()
            offline("B available without a verified VLESS response")
            assert not gate_b.forwarded.is_set(), "an unsolicited bootstrap reached endpoint B"
            assert not echo_b.is_set() and not dns_b.is_set()
            assert ordinary_echo(mixed_port), "ordinary core failed to resolve and authenticate endpoint B"
            app.verify("ONLINE", "ordinary endpoint B authenticated; child TCP and DNS through B")
            assert echo_b.wait(2) and dns_b.wait(2), "B did not observe the child's distinct TCP and DNS"
            assert not echo_a.is_set() and not dns_a.is_set(), "old endpoint A still carried application traffic"

            stop()
            app.verify("OFFLINE", "stopped")
            offline("no profile after stop")
            activate({"type": "direct", "tag": "only-direct"})
            offline("DIRECT after previously verified B")
        finally:
            stream.cancel()
        canary.setblocking(False)
        try:
            unexpected, _ = canary.accept()
        except BlockingIOError:
            pass
        else:
            unexpected.close()
            raise AssertionError("a direct application connection reached the parent")
        print("PASS verified A and B; same child; TCP and DNS observed by each peer; DIRECT denied", flush=True)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="hostname-profile-") as scratch:
        check(Path(sys.argv[1]).resolve(strict=True), Path(scratch), Path(sys.argv[2]).resolve(strict=True))
