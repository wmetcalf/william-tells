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
    def __init__(self, tmp: Path, slot: int, scanner: Path = SCANNER):
        self.port = _free_port()
        self.log = tmp / f"agent-{slot}.log"
        env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin",
               "WTQRK_SCAN_BIN": str(scanner), "WTQRK_WORKER_SLOT": str(slot),
               "WTQRK_SLOT_ROOT": str(tmp / "slots"),
               "BLASTBOX_WORKER_AGENT_TOKEN": TOKEN,
               "BLASTBOX_WORKER_AGENT_PORT": str(self.port)}
        self.proc = subprocess.Popen([str(WORKER)], env=env, stdout=self.log.open("wb"),
                                     stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                self.health()
                return
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
                          "self_test": "passed"}
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
        assert a.health()["self_test"] == "failed"
        body = _qr("https://native.example/should-not-matter", tmp_path)
        env = _gate(a.detonate(body), body, tmp_path)
        assert env.status == "engine_error"
        assert env.payload.fields["error"] == "self_test_failed"
        assert "payloads" not in env.payload.fields
    finally:
        a.stop()
