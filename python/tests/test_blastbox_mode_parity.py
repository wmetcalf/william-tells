"""`wtqrk-scan blastbox` (Swift) and the Python engine map one scan document to the same envelope.

Both read Tests/QRSandboxTests/Fixtures/blastbox-mode: scan.json is the scanner's document,
expected-envelope.json the envelope. The Swift side (BlastboxModeTests) asserts it produces
exactly that file; this test asserts the Python mapping does too, so a push-path result and a
pull-path result are indistinguishable.
"""
from __future__ import annotations

import json
from pathlib import Path

from blastbox.contract import Record
from blastbox.limits import Limits
from blastbox.worker.sandbox.base import SandboxResult
from test_engine import _engine, _fresh_self_test_cache  # noqa: F401

FIX = Path(__file__).resolve().parents[2] / "Tests" / "QRSandboxTests" / "Fixtures" / "blastbox-mode"


def _plain(v):
    if isinstance(v, Record):
        return {"_type": "record", "fields": {k: _plain(x) for k, x in v.fields.items()}}
    if isinstance(v, list):
        return [_plain(x) for x in v]
    return v


def envelope_from_python(tmp_path, scan_stdout: bytes, data: bytes, sha: str) -> dict:
    eng, _ = _engine(tmp_path, scan_stdout)
    p = tmp_path / "in.bin"
    p.write_bytes(data)
    res = eng.detonate(p, tmp_path, Limits())
    d = res.detected
    return {"engine": "williamtells", "status": res.status, "input_sha256": sha,
            "detected": {"label": d.label, "mime": d.mime, "confidence": d.confidence,
                         "source": d.source},
            "artifacts": [],
            "warnings": [{"code": w.code, "message": w.message} for w in res.warnings],
            "payload": _plain(res.payload)}


def test_python_mapping_equals_the_committed_envelope(tmp_path):
    data = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    got = envelope_from_python(tmp_path, (FIX / "scan.json").read_bytes(), data, "ab" * 32)
    assert got == json.loads((FIX / "expected-envelope.json").read_text())
