"""WilliamTellsEngine: untrusted-output validation, the self-test gate, and real sandboxed runs.

Unit tests use a fake sandbox and run anywhere. ``TestReal*`` needs macOS plus a built
``wtqrk-scan`` (``swift build -c release`` at the repo root, or WTQRK_SCAN_BIN).
"""
from __future__ import annotations

import hashlib
import json
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

import pytest
from blastbox.contract import Record
from blastbox.limits import Limits
from blastbox.worker.sandbox.base import SandboxResult

from william_tells import blastbox_engine as wt
from william_tells.blastbox_engine import WilliamTellsEngine, parse_scan_output, sniff

REPO = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("WTQRK_SCAN_BIN") or REPO / ".build" / "release" / "wtqrk-scan")
REAL = sys.platform == "darwin" and BIN.is_file()
needs_real = pytest.mark.skipif(not REAL, reason="needs macOS + built wtqrk-scan")


@pytest.fixture(autouse=True)
def _fresh_self_test_cache(monkeypatch):
    monkeypatch.setattr(WilliamTellsEngine, "_self_test_ok", None)
    monkeypatch.setattr(WilliamTellsEngine, "_self_test_detail", "")
    monkeypatch.setattr(WilliamTellsEngine, "_plan_cache", None)
    for k in ("WTQRK_MODE", "WTQRK_CONFIG", "WTQRK_SELF_TEST"):
        monkeypatch.delenv(k, raising=False)


def _ok_doc(dets, **over):
    doc = {"schema": wt.SCHEMA, "ok": True, "mode": "default", "compute": "auto",
           "report": {"imageDimensions": {"width": 100, "height": 50}, "mutationsTried": 3,
                      "detections": dets}}
    doc.update(over)
    return json.dumps(doc).encode()


DET = {"payload": "https://x", "symbology": "VNBarcodeSymbologyQR", "confidence": 1.0,
       "boundingBox": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4}}


class FakeSandbox:
    name = "fake"

    def __init__(self, scan: SandboxResult, self_test_ok: bool = True):
        self.scan = scan
        self.self_test_ok = self_test_ok
        self.requests = []

    def run(self, req):
        self.requests.append(req)
        if req.argv[1] == "self-test":
            body = json.dumps({"ok": self.self_test_ok}).encode()
            return SandboxResult(exit_code=0 if self.self_test_ok else 1, stdout=body, stderr=b"")
        return self.scan


def _engine(tmp_path, scan_stdout=b"", rc=0, killed=False, self_test_ok=True):
    exe = tmp_path / "wtqrk-scan"
    exe.write_text("#!/bin/sh\n")
    sb = FakeSandbox(SandboxResult(exit_code=rc, stdout=scan_stdout, stderr=b"err", killed=killed),
                     self_test_ok=self_test_ok)
    return WilliamTellsEngine(scan_bin=str(exe), sandbox=sb), sb


def _input(tmp_path, data=b"\x89PNG\r\n\x1a\n" + b"\0" * 32):
    p = tmp_path / "in.bin"
    p.write_bytes(data)
    return p


class TestParseScanOutput:
    def test_valid(self):
        doc, warns = parse_scan_output(_ok_doc([DET]))
        assert doc["detections"][0]["payload"] == "https://x" and not warns

    @pytest.mark.parametrize("bad", [
        b"not json", b"[]", json.dumps({"schema": "other", "ok": True}).encode(),
        _ok_doc([{**DET, "confidence": 2.0}]),
        _ok_doc([{**DET, "confidence": True}]),
        _ok_doc([{**DET, "payload": 7}]),
        _ok_doc([{**DET, "boundingBox": "x"}]),
        _ok_doc("nope"),
    ])
    def test_rejects_malformed(self, bad):
        with pytest.raises(ValueError):
            parse_scan_output(bad)

    def test_rejects_nan(self):
        raw = _ok_doc([DET]).replace(b'"confidence": 1.0', b'"confidence": NaN')
        with pytest.raises(ValueError):
            parse_scan_output(raw)

    def test_oversize_output_rejected(self):
        with pytest.raises(ValueError, match="exceeds"):
            parse_scan_output(b" " * (wt.MAX_STDOUT_BYTES + 1))

    def test_truncation_is_reported(self):
        dets = [{**DET, "payload": "p" * (wt.MAX_PAYLOAD_CHARS + 5)}] * (wt.MAX_DETECTIONS + 1)
        doc, warns = parse_scan_output(_ok_doc(dets))
        assert len(doc["detections"]) == wt.MAX_DETECTIONS
        assert {w.code for w in warns} == {"detections_truncated", "payload_truncated"}
        assert len(doc["detections"][0]["payload"]) == wt.MAX_PAYLOAD_CHARS


class TestDetonate:
    def test_maps_to_record_and_requests_accelerators(self, tmp_path):
        eng, sb = _engine(tmp_path, _ok_doc([DET]))
        res = eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert res.status == "ok"
        f = res.payload.fields
        assert f["payloads"] == ["https://x"] and f["detection_count"] == 1
        assert isinstance(f["detections"], Record)
        assert f["detections"].fields["0"].fields["bbox_w"] == pytest.approx(0.3)
        scan = sb.requests[-1]
        assert scan.accelerators == frozenset({"gpu", "ane"})
        assert [m.source for m in scan.ro_mounts] == [tmp_path / "in.bin"]
        assert res.detected.label == "png"

    def test_failed_self_test_is_an_engine_error_not_a_clean_result(self, tmp_path):
        eng, sb = _engine(tmp_path, _ok_doc([]), self_test_ok=False)
        res = eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert res.status == "engine_error"
        assert res.warnings[0].code == "self_test_failed"
        assert all(r.argv[1] == "self-test" for r in sb.requests)   # never scanned

    def test_self_test_captures_and_scans_are_seeded(self, tmp_path):
        eng, sb = _engine(tmp_path, _ok_doc([]))

        def capture_writes(req, _orig=sb.run):
            if req.capture_home is not None:
                (req.capture_home / "Library").mkdir()
            return _orig(req)
        sb.run = capture_writes
        eng.detonate(_input(tmp_path), tmp_path, Limits())
        st, scan = sb.requests
        assert st.argv[1] == "self-test" and st.capture_home is not None and st.seed_home is None
        assert scan.seed_home == st.capture_home and scan.capture_home is None

    def test_self_test_runs_once_per_process(self, tmp_path):
        eng, sb = _engine(tmp_path, _ok_doc([]))
        for _ in range(3):
            eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert [r.argv[1] for r in sb.requests].count("self-test") == 1

    def test_warmup_raises_on_failed_self_test(self, tmp_path):
        eng, _ = _engine(tmp_path, self_test_ok=False)
        with pytest.raises(wt.SelfTestFailed):
            eng.warmup()

    def test_heavy_mode_and_config_forwarded(self, tmp_path, monkeypatch):
        monkeypatch.setenv("WTQRK_MODE", "heavy")
        monkeypatch.setenv("WTQRK_CONFIG", '{"scales": [1.0, 2]}')
        eng, sb = _engine(tmp_path, _ok_doc([]))
        eng.detonate(_input(tmp_path), tmp_path, Limits())
        argv = sb.requests[-1].argv
        assert "--heavy" in argv
        assert argv[argv.index("--config-json") + 1] == '{"scales":[1.0,2]}'

    @pytest.mark.parametrize("mode,cfg", [
        ("turbo", ""), ("default", "{"), ("default", '{"evil": [1]}'),
        ("default", '{"scales": [1e999]}'), ("default", '{"scales": [true]}'),
    ])
    def test_bad_params_rejected_before_scanning(self, tmp_path, monkeypatch, mode, cfg):
        monkeypatch.setenv("WTQRK_MODE", mode)
        monkeypatch.setenv("WTQRK_CONFIG", cfg)
        eng, sb = _engine(tmp_path, _ok_doc([]))
        res = eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert res.status == "rejected"
        assert all(r.argv[1] == "self-test" for r in sb.requests)

    def test_killed_scanner(self, tmp_path):
        eng, _ = _engine(tmp_path, b"", rc=-9, killed=True)
        res = eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert res.status == "engine_error" and res.warnings[0].code == "scanner_killed"

    @pytest.mark.parametrize("rc", [1, 139, -11])
    def test_ok_output_from_a_failed_exit_is_an_engine_error(self, tmp_path, rc):
        eng, _ = _engine(tmp_path, _ok_doc([DET]), rc=rc)
        res = eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert res.status == "engine_error" and res.warnings[0].code == "scanner_failed"

    def test_garbage_output_is_an_engine_error(self, tmp_path):
        eng, _ = _engine(tmp_path, b"\x00\xff garbage")
        res = eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert res.status == "engine_error" and res.warnings[0].code == "bad_scanner_output"

    def test_bad_image_is_rejected(self, tmp_path):
        out = json.dumps({"schema": wt.SCHEMA, "ok": False,
                          "error": {"code": "invalid_image", "message": "nope"}}).encode()
        eng, _ = _engine(tmp_path, out, rc=2)
        res = eng.detonate(_input(tmp_path), tmp_path, Limits())
        assert res.status == "rejected" and res.warnings[0].code == "invalid_image"


# ----------------------------------------------------------------------------------------------
# Real: macOS sandbox + the built CLI + blastbox's harness and host trust gate.
# ----------------------------------------------------------------------------------------------

def _render_qr(message: str, out: Path) -> Path:
    subprocess.run([str(BIN), "render-qr", message, str(out)], check=True)
    return out


def _png_bomb(width: int, height: int) -> bytes:
    """A complete, valid 1-bit grayscale PNG: tens of KB on disk, width*height pixels decoded."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    row = b"\x00" + b"\x00" * ((width + 7) // 8)          # filter byte + packed bits
    comp = zlib.compressobj(9)
    idat = b"".join(comp.compress(row) for _ in range(height)) + comp.flush()
    ihdr = struct.pack(">IIBBBBB", width, height, 1, 0, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat)
            + chunk(b"IEND", b""))


def _sealed_run(engine, input_path: Path, tmp_path: Path):
    """Harness -> metadata.json -> host trust gate, exactly as a worker + dispatcher would."""
    from blastbox.host.trust import validate_worker_output
    from blastbox.worker.harness import run_detonation
    out = tmp_path / "out"
    limits = Limits(timeout_s=120)
    assert run_detonation(engine, input_path=input_path, output_dir=out, limits=limits) == 0
    sha = hashlib.sha256(input_path.read_bytes()).hexdigest()
    return validate_worker_output(output_dir=out, input_sha256=sha, engine=engine.name,
                                  limits=limits)


@needs_real
class TestRealSeatbelt:
    @pytest.fixture
    def engine(self, monkeypatch):
        monkeypatch.setenv("BLASTBOX_SANDBOX", "seatbelt")
        return WilliamTellsEngine(scan_bin=str(BIN))

    def test_self_test_passes_in_the_sandbox(self, engine):
        ok, detail = engine.self_test()
        assert ok, detail
        assert engine._sb().name == "seatbelt"
        assert WilliamTellsEngine._plan_cache is not None     # warm cache was captured

    def test_seeded_scans_are_fast_and_correct(self, engine, tmp_path):
        import time
        qr = _render_qr("https://william-tells.example/warm", tmp_path / "qr.png")
        engine.self_test()
        t0 = time.perf_counter()
        res = engine.detonate(qr, tmp_path, Limits(timeout_s=60))
        elapsed = time.perf_counter() - t0
        assert res.payload.fields["payloads"] == ["https://william-tells.example/warm"]
        assert elapsed < 0.8, f"seeded scan took {elapsed:.2f}s; plan cache not reused?"

    def test_qr_end_to_end_through_the_host_trust_gate(self, engine, tmp_path):
        msg = "https://william-tells.example/e2e"
        env = _sealed_run(engine, _render_qr(msg, tmp_path / "qr.png"), tmp_path)
        assert env.status == "ok"
        payload = env.payload
        assert payload.fields["payloads"] == [msg]
        assert payload.fields["schema"] == wt.SCHEMA

    def test_decompression_bomb_is_rejected(self, engine, tmp_path):
        bomb = tmp_path / "bomb.png"
        bomb.write_bytes(_png_bomb(20000, 20000))
        assert bomb.stat().st_size < 1_000_000
        res = engine.detonate(bomb, tmp_path, Limits(timeout_s=60))
        assert res.status == "rejected"
        assert "limit" in res.warnings[0].message

    def test_garbage_is_rejected(self, engine, tmp_path):
        p = tmp_path / "junk.bin"
        p.write_bytes(os.urandom(4096))
        assert engine.detonate(p, tmp_path, Limits(timeout_s=60)).status == "rejected"

    def test_blank_image_finds_nothing_but_is_ok(self, engine, tmp_path):
        # A real negative AFTER a passing self-test is a trustworthy "nothing here".
        p = _render_qr("x", tmp_path / "qr.png")
        blank = tmp_path / "blank.png"
        # Same header, but all-white pixels: corrupt the IDAT? Simpler: a tiny white BMP.
        w = h = 64
        row = b"\xff\xff\xff" * w
        bmp = (b"BM" + struct.pack("<IHHI", 54 + len(row) * h, 0, 0, 54)
               + struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(row) * h, 2835, 2835, 0, 0)
               + row * h)
        blank.write_bytes(bmp)
        res = engine.detonate(blank, tmp_path, Limits(timeout_s=60))
        assert res.status == "ok", res.warnings
        assert res.payload.fields["detection_count"] == 0
        assert p.exists()


@needs_real
class TestRealAppSandbox:
    @pytest.fixture
    def engine(self, tmp_path_factory, monkeypatch):
        from blastbox.worker.sandbox.appsandbox import AppSandboxSandbox, prepare
        root = tmp_path_factory.mktemp("wt-asroot")
        prepare(root, slots=1, ro_paths=[BIN.parent], bundle_prefix="io.blastbox.pytest.wt")
        return WilliamTellsEngine(scan_bin=str(BIN), sandbox=AppSandboxSandbox(root=root))

    def test_qr_end_to_end(self, engine, tmp_path):
        msg = "https://william-tells.example/appsandbox"
        env = _sealed_run(engine, _render_qr(msg, tmp_path / "qr.png"), tmp_path)
        assert env.status == "ok"
        assert env.payload.fields["payloads"] == [msg]


# `detected` for a completed scan is the type the (sandboxed) scanner reported; the host only
# sniffs magic numbers and never parses XML itself.
def test_a_completed_scan_is_labelled_with_the_scanners_input_type(tmp_path):
    doc = b"<!-- " + b"x" * 4000 + b' --><svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>'
    eng, _ = _engine(tmp_path, _ok_doc([DET], inputType="svg"))
    res = eng.detonate(_input(tmp_path, doc), tmp_path, Limits())
    assert res.status == "ok"
    assert (res.detected.label, res.detected.mime, res.detected.confidence) == (
        "svg", "image/svg+xml", 1.0)


def test_without_an_input_type_the_label_is_the_magic_sniff(tmp_path):
    eng, _ = _engine(tmp_path, _ok_doc([DET]))
    res = eng.detonate(_input(tmp_path), tmp_path, Limits())
    assert res.detected.label == "png"
    assert sniff(b"<svg/>")[0] == "unknown"           # no XML parsing on the host
    assert sniff(b"\x89PNG\r\n\x1a\n<svg>")[0] == "png"


@pytest.mark.parametrize("bad", ["exe", 7, "../svg", ["svg"]])
def test_an_unknown_input_type_is_bad_output(tmp_path, bad):
    with pytest.raises(ValueError, match="inputType"):
        parse_scan_output(_ok_doc([DET], inputType=bad))
    eng, _ = _engine(tmp_path, _ok_doc([DET], inputType=bad))
    res = eng.detonate(_input(tmp_path), tmp_path, Limits())
    assert res.status == "engine_error" and res.warnings[0].code == "bad_scanner_output"


@pytest.mark.parametrize("brand,label", [(b"heic", "heic"), (b"heix", "heic"), (b"heim", "heic"),
                                         (b"heis", "heic"), (b"mif1", "heif"), (b"msf1", "heif")])
def test_the_magic_sniff_separates_heif_from_heic(brand, label):
    head = b"\0\0\0\x18ftyp" + brand + b"\0" * 12
    assert sniff(head) == (label, f"image/{label}")


def test_a_heif_input_type_is_reported_as_image_heif(tmp_path):
    eng, _ = _engine(tmp_path, _ok_doc([DET], inputType="heif"))
    res = eng.detonate(_input(tmp_path), tmp_path, Limits())
    assert (res.detected.label, res.detected.mime) == ("heif", "image/heif")
