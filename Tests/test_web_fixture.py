"""The actual loopback fixture must not depend on reverse-DNS availability."""

import http.client
import subprocess
import sys
import time
from pathlib import Path

import pytest

FIXTURE = Path(__file__).parent / "VerdictUIWebTests" / "Fixtures" / "server.py"
LAUNCH_WITH_BROKEN_DNS = """
import runpy, socket, sys, threading
fixture, mode, root, port = sys.argv[1:]
def reverse_dns_unavailable(*args):
    if mode == "stalled":
        threading.Event().wait(30)
    raise AssertionError("loopback fixture attempted reverse DNS")
socket.getfqdn = reverse_dns_unavailable
sys.argv = [fixture, root, port]
runpy.run_path(fixture, run_name="__main__")
"""


@pytest.mark.parametrize("dns_mode", ["unavailable", "stalled"])
def test_loopback_fixture_starts_and_serves_without_reverse_dns(tmp_path, dns_mode):
    port_file = tmp_path / "server.port"
    with (tmp_path / "server.log").open("w+b") as output:
        process = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-c",
                LAUNCH_WITH_BROKEN_DNS,
                str(FIXTURE),
                dns_mode,
                str(FIXTURE.parent),
                str(port_file),
            ],
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=output,
        )
        try:
            deadline = time.monotonic() + 5
            while not port_file.exists() and process.poll() is None and time.monotonic() < deadline:
                try:
                    process.wait(timeout=0.01)
                except subprocess.TimeoutExpired:
                    continue
            output.seek(0)
            diagnostics = output.read(4096).decode(errors="replace")
            assert port_file.exists(), f"fixture failed to publish its port: {diagnostics}"
            assert process.poll() is None, f"fixture exited before serving: {diagnostics}"
            connection = http.client.HTTPConnection(
                "127.0.0.1", int(port_file.read_text()), timeout=2
            )
            try:
                for route, expected in (
                    ("/same", b"http://127.0.0.1:"),
                    ("/cross", b"http://localhost:"),
                    ("/clean.html", b'id="save"'),
                    ("/login.html?hash=synthetic", b'id="password"'),
                    ("/slow", b"Network task complete"),
                ):
                    connection.request("GET", route)
                    response = connection.getresponse()
                    assert response.status == 200
                    assert expected in response.read()
            finally:
                connection.close()
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
