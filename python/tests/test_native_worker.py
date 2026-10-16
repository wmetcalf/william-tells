"""The native Swift agent (`wtqrk-worker`) against blastbox's own host-side trust gate.

Starts the real agent on a free port with throwaway slots, POSTs images the way blastbox's
`remote_http` transport does, and runs every returned tar through `validate_worker_output` --
the same gate the dispatcher applies -- so the agent is held to blastbox's contract, not to a
re-statement of it. Needs `swift build -c release` (wtqrk-worker + wtqrk-scan) on macOS.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import pytest
from blastbox.host.dispatch import validate_worker_output
from blastbox.limits import Limits

REPO = Path(__file__).resolve().parents[2]
WORKER = REPO / ".build" / "release" / "wtqrk-worker"
SCANNER = REPO / ".build" / "release" / "wtqrk-scan"
TOKEN = "native-test-token"

pytestmark = pytest.mark.skipif(
    sys.platform != "darwin" or not WORKER.exists() or not SCANNER.exists(),
    reason="needs macOS and `swift build -c release`")


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Agent:
    def __init__(self, tmp: Path, slot: int, scanner: Path = SCANNER, env: dict | None = None):
        self.port = _free_port()
        self.log = tmp / f"agent-{slot}.log"
        env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin",
               "WTQRK_SCAN_BIN": str(scanner), "WTQRK_WORKER_SLOT": str(slot),
               "WTQRK_SLOT_ROOT": str(tmp / "slots"),
               "BLASTBOX_WORKER_AGENT_TOKEN": TOKEN,
               "BLASTBOX_WORKER_AGENT_PORT": str(self.port), **(env or {})}
        self.proc = subprocess.Popen([str(WORKER)], env=env, stdout=self.log.open("wb"),
                                     stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                self.health()
                return
            except urllib.error.HTTPError:
                return          # up, and answering (e.g. 503 when its self-test failed)
            except OSError:
                time.sleep(0.2)
        self.stop()
        raise RuntimeError("agent did not start: " + self.log.read_text()[-2000:])

    def health(self, token: str | None = TOKEN) -> dict:
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/healthz")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())

    def detonate(self, body: bytes, params: dict | None = None) -> bytes:
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/detonate?name=in.png",
                                     data=body, method="POST")
        req.add_header("X-aws-proxy-auth", TOKEN)
        if params:
            req.add_header("X-Blastbox-Params", json.dumps(params))
        with urllib.request.urlopen(req, timeout=120) as r:
            assert r.headers["Content-Type"] == "application/x-tar"
            return r.read()

    def stop(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def _gate(tar_bytes: bytes, body: bytes, tmp: Path):
    """The dispatcher's trust gate on the agent's tar."""
    out = tmp / f"out-{uuid.uuid4().hex}"
    out.mkdir()
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tf:
        assert tf.getnames() == ["metadata.json"]
        tf.extractall(out, filter="data")
    return validate_worker_output(output_dir=out, input_sha256=hashlib.sha256(body).hexdigest(),
                                  engine="williamtells", limits=Limits())


def _qr(msg: str, tmp: Path) -> bytes:
    p = tmp / f"{uuid.uuid4().hex}.png"
    subprocess.run([str(SCANNER), "render-qr", msg, str(p)], check=True)
    return p.read_bytes()


@pytest.fixture(scope="module")
def agent(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("native")
    a = Agent(tmp, slot=950)
    yield a, tmp
    a.stop()


def test_health_requires_the_token(agent):
    a, _ = agent
    assert a.health() == {"ok": True, "engine": "williamtells", "agent": "wtqrk-worker",
                          "self_test": "passed", "slot": "ok"}
    with pytest.raises(urllib.error.HTTPError) as exc:
        a.health(token="wrong")
    assert exc.value.code == 401


def test_scan_passes_the_host_trust_gate(agent):
    a, tmp = agent
    msg = f"https://native.example/{uuid.uuid4()}"
    body = _qr(msg, tmp)
    env = _gate(a.detonate(body, {"WTQRK_MODE": "heavy"}), body, tmp)
    assert env.status == "ok"
    assert env.detected.label == "png"
    assert env.payload.fields["payloads"] == [msg]
    assert env.payload.fields["mode"] == "heavy"
    assert env.payload.fields["schema"] == "wtqrk.scan/1"


def test_bad_input_and_params_are_rejected(agent):
    a, tmp = agent
    junk = os.urandom(4096)
    env = _gate(a.detonate(junk), junk, tmp)
    assert env.status == "rejected" and env.payload.fields["error"] == "invalid_image"
    body = _qr("x", tmp)
    env = _gate(a.detonate(body, {"WTQRK_MODE": "turbo"}), body, tmp)
    assert env.status == "rejected" and env.payload.fields["error"] == "bad_param"
    env = _gate(a.detonate(body, {"WTQRK_CONFIG": '{"evil":[1]}'}), body, tmp)
    assert env.status == "rejected" and env.payload.fields["error"] == "bad_config"


def test_a_scanner_that_cannot_be_sandboxed_fails_closed(tmp_path):
    # /bin/echo is not a wtqrk-scan (and has no embedded Info.plist, so App Sandbox can't even
    # launch it): the self-test gate fails, and every job is engine_error -- never "no QR".
    fake = tmp_path / "fake-scan"
    shutil.copy("/bin/echo", fake)
    a = Agent(tmp_path, slot=951, scanner=fake)
    try:
        with pytest.raises(urllib.error.HTTPError) as exc:
            a.health()
        assert exc.value.code == 503      # a static pool skips this Mac
        assert json.loads(exc.value.read())["self_test"] == "failed"
        body = _qr("https://native.example/should-not-matter", tmp_path)
        env = _gate(a.detonate(body), body, tmp_path)
        assert env.status == "engine_error"
        assert env.payload.fields["error"] == "self_test_failed"
        assert "payloads" not in env.payload.fields
    finally:
        a.stop()


def test_a_retired_slot_makes_the_agent_unhealthy(tmp_path):
    # The agent has one slot. Swap its container for a symlink (what a hostile scanner could do
    # to its own container): the post-job wipe refuses to follow it, retires the slot, and from
    # then on /healthz is 503 so a static pool stops sending jobs here.
    a = Agent(tmp_path, slot=952)
    data = Path.home() / "Library/Containers/io.github.wmetcalf.wtqrk-scan.slot952/Data"
    try:
        assert a.health()["slot"] == "ok"
        decoy = tmp_path / "decoy"
        decoy.mkdir()
        (decoy / "precious").write_text("keep")
        try:
            os.rename(data, tmp_path / "real-data")
            os.symlink(decoy, data)
        except OSError as e:
            pytest.skip(f"cannot replace the container here (macOS container protection): {e}")
        body = _qr("x", tmp_path)
        env = _gate(a.detonate(body), body, tmp_path)
        assert env.status == "engine_error" and env.payload.fields["error"] == "no_clean_slot"
        assert (decoy / "precious").read_text() == "keep"       # not followed
        with pytest.raises(urllib.error.HTTPError) as exc:
            a.health()
        assert exc.value.code == 503
        assert json.loads(exc.value.read())["slot"] == "retired"
    finally:
        a.stop()
        if data.is_symlink():
            data.unlink()
        if (tmp_path / "real-data").exists():      # moved out, even if the symlink was refused
            os.rename(tmp_path / "real-data", data)


def test_rejected_uploads_are_not_buffered(agent):
    # Auth runs before the body is read (a streamed route): 150 MB -- past the 100 MiB cap --
    # from a peer with the wrong token is discarded as it arrives, never collected in memory.
    a, _ = agent

    def rss_kb() -> int:
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(a.proc.pid)]))

    before, peak, n = rss_kb(), 0, 150
    chunk = b"\0" * (1 << 20)
    with socket.create_connection(("127.0.0.1", a.port), timeout=30) as s:
        s.sendall((f"POST /detonate?name=in.png HTTP/1.1\r\nHost: x\r\nX-aws-proxy-auth: wrong\r\n"
                   f"Content-Length: {n << 20}\r\n\r\n").encode())
        for i in range(n):
            s.sendall(chunk)
            if i % 25 == 0:
                peak = max(peak, rss_kb())
        status = s.recv(4096).split(b"\r\n", 1)[0]
    assert status.split()[1] == b"401", status
    assert peak - before < 32 << 10, f"worker grew {peak - before} KB on a rejected upload"


def _gate_env(tmp_path, cidrs):
    return {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin",
            "WTQRK_SLOT_ROOT": str(tmp_path / "slots"), "WTQRK_WORKER_SLOT": "953",
            "BLASTBOX_WORKER_AGENT_BIND": "0.0.0.0", "BLASTBOX_WORKER_AGENT_PORT": str(_free_port()),
            "BLASTBOX_WORKER_AGENT_ALLOW_CIDRS": cidrs}


@pytest.mark.parametrize("cidrs", [
    "0.0.0.0/0",
    "10.0.0.0/8,::/0",
    # no entry is /0, but together they admit every address of a family
    "0.0.0.0/1,128.0.0.0/1",
    "0.0.0.0/2,64.0.0.0/2,128.0.0.0/1",
    "128.0.0.0/2,10.0.0.0/8,0.0.0.0/1,100.0.0.0/8,192.0.0.0/2",     # overlapping, unsorted
    "0.0.0.1/1,255.255.255.255/1",                                  # host bits set
    "::/1,8000::/1",
    "::ffff:0.0.0.0/97,::ffff:128.0.0.0/97",                        # every IPv4-mapped peer
])
def test_a_catch_all_allowlist_is_not_a_gate(tmp_path, cidrs):
    # An allowlist admitting everyone gates nothing: with no token, a non-loopback bind is refused.
    r = subprocess.run([str(WORKER)], env=_gate_env(tmp_path, cidrs), capture_output=True, timeout=60)
    assert r.returncode == 78, r
    assert b"refusing to serve" in r.stdout + r.stderr


@pytest.mark.parametrize("cidrs", [
    "10.0.0.0/8",
    "0.0.0.0/1,128.0.0.0/2,192.0.0.0/3,224.0.0.0/4,240.0.0.0/5,248.0.0.0/6,252.0.0.0/7,"
    "254.0.0.0/8,255.0.0.0/9,255.128.0.0/10,255.192.0.0/11,255.224.0.0/12,255.240.0.0/13,"
    "255.248.0.0/14,255.252.0.0/15,255.254.0.0/16,255.255.0.0/17,255.255.128.0/18,"
    "255.255.192.0/19,255.255.224.0/20,255.255.240.0/21,255.255.248.0/22,255.255.252.0/23,"
    "255.255.254.0/24,255.255.255.0/25,255.255.255.128/26,255.255.255.192/27,"
    "255.255.255.224/28,255.255.255.240/29,255.255.255.248/30,255.255.255.252/31,"
    "255.255.255.254/32",                       # every IPv4 address but 255.255.255.255
    "0.0.0.0/1,::ffff:128.0.0.0/97",            # halves of different families don't add up
])
def test_an_allowlist_that_leaves_addresses_out_is_a_gate(tmp_path, cidrs):
    proc = subprocess.Popen([str(WORKER)], env=_gate_env(tmp_path, cidrs),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        out, _ = proc.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
    assert b"refusing to serve" not in out, out


def test_a_trickled_upload_cannot_hold_the_worker(tmp_path):
    # An authenticated client that sends a few bytes and stalls loses the single-flight slot
    # at the upload deadline, so the next real job runs instead of getting 409 forever.
    a = Agent(tmp_path, 954, env={"BLASTBOX_WORKER_AGENT_UPLOAD_TIMEOUT": "2"})
    try:
        with socket.create_connection(("127.0.0.1", a.port), timeout=30) as s:
            s.sendall((f"POST /detonate?name=in.png HTTP/1.1\r\nHost: x\r\nX-aws-proxy-auth: {TOKEN}\r\n"
                       "Content-Length: 1000000\r\n\r\n").encode() + b"\x89PNG")
            time.sleep(0.5)
            with pytest.raises(urllib.error.HTTPError) as busy:
                a.detonate(_qr("blocked", tmp_path))
            assert busy.value.code == 409
            time.sleep(2.5)
            tar_bytes = a.detonate(_qr("https://after-trickle.example/", tmp_path))
            assert b"after-trickle.example" in tar_bytes
    finally:
        a.stop()


def _until_closed(s: socket.socket, within: float) -> bytes:
    """Everything the server sends until it closes the connection; fails if it is still open
    `within` seconds from now."""
    s.settimeout(within)
    got = b""
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        try:
            part = s.recv(65536)
        except TimeoutError:
            break
        except ConnectionResetError:
            return got
        if not part:
            return got
        got += part
    raise AssertionError(f"connection still open after {within}s; got {got[:200]!r}")


def test_an_over_limit_streamed_upload_is_closed_not_drained(tmp_path):
    # Chunked, so there is no Content-Length to refuse up front: the cap trips mid-stream. The
    # client then stalls; the server must answer 413 and close, not wait for the rest while it
    # holds the buffered megabyte.
    limit = 1 << 20
    a = Agent(tmp_path, 955, env={"BLASTBOX_WORKER_AGENT_MAX_BYTES": str(limit)})
    try:
        with socket.create_connection(("127.0.0.1", a.port), timeout=30) as s:
            s.sendall((f"POST /detonate?name=in.png HTTP/1.1\r\nHost: x\r\nX-aws-proxy-auth: {TOKEN}\r\n"
                       "Transfer-Encoding: chunked\r\n\r\n").encode())
            chunk = b"\0" * (64 << 10)
            for _ in range(limit // len(chunk)):
                s.sendall(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
            s.sendall(b"1\r\n\0\r\n")                      # one byte over the cap, then nothing
            reply = _until_closed(s, 5)
        head, _, body = reply.partition(b"\r\n\r\n")
        assert head.split(b"\r\n", 1)[0].split()[1] == b"413", reply[:200]
        assert b"too_large" in body
        # the worker is free again: the connection's end released the single-flight slot
        tar_bytes = a.detonate(_qr("https://after-overlimit.example/", tmp_path))
        assert b"after-overlimit.example" in tar_bytes
    finally:
        a.stop()


def test_a_timed_out_upload_is_closed_not_drained(tmp_path):
    a = Agent(tmp_path, 956, env={"BLASTBOX_WORKER_AGENT_UPLOAD_TIMEOUT": "2"})
    try:
        with socket.create_connection(("127.0.0.1", a.port), timeout=30) as s:
            s.sendall((f"POST /detonate?name=in.png HTTP/1.1\r\nHost: x\r\nX-aws-proxy-auth: {TOKEN}\r\n"
                       "Content-Length: 1000000\r\n\r\n").encode() + b"\x89PNG")
            reply = _until_closed(s, 6)                     # 2 s deadline + slack
        assert reply.split(b"\r\n", 1)[0].split()[1] == b"408", reply[:200]
        assert b"upload_timeout" in reply
    finally:
        a.stop()


def test_a_declared_over_limit_upload_is_closed(tmp_path):
    a = Agent(tmp_path, 957, env={"BLASTBOX_WORKER_AGENT_MAX_BYTES": str(1 << 20)})
    try:
        with socket.create_connection(("127.0.0.1", a.port), timeout=30) as s:
            s.sendall((f"POST /detonate?name=in.png HTTP/1.1\r\nHost: x\r\nX-aws-proxy-auth: {TOKEN}\r\n"
                       f"Content-Length: {50 << 20}\r\n\r\n").encode() + b"\0" * 1024)
            reply = _until_closed(s, 5)
        assert reply.split(b"\r\n", 1)[0].split()[1] == b"413", reply[:200]
    finally:
        a.stop()
