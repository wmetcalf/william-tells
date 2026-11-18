"""The engine contract file itself, and a real (fake-sandbox) result checked against it."""
from __future__ import annotations

import dataclasses
import json
from pathlib import Path

import pytest

ec = pytest.importorskip("blastbox.contract.engine_contract")

from blastbox.contract import Record  # noqa: E402
from blastbox.limits import Limits  # noqa: E402
from blastbox.worker.sandbox.base import SandboxResult  # noqa: E402

from william_tells import blastbox_engine as wt  # noqa: E402

CONTRACT_PATH = Path(__file__).resolve().parents[2] / "blastbox-engine.toml"


def test_the_contract_validates():
    assert ec.find_contract(Path(__file__)) == CONTRACT_PATH
    c = ec.load_contract(CONTRACT_PATH)
    assert ec.main(["validate", str(CONTRACT_PATH)]) == 0
    assert c.engine.name == wt.ENGINE_NAME
    assert set(c.engine.formats) == set(wt.WilliamTellsEngine.formats)
    assert c.payload.schema_version == wt.SCHEMA
    assert [x.engine for x in c.consumers if x.name == "loadout"] == ["williamtells"]


class _Sandbox:
    name = "fake"

    def __init__(self, stdout: bytes):
        self.stdout = stdout

    def run(self, req):
        if req.argv[1] == "self-test":
            return SandboxResult(exit_code=0, stdout=b'{"ok": true}', stderr=b"")
        return SandboxResult(exit_code=0, stdout=self.stdout, stderr=b"")


def test_an_ok_scan_conforms_and_a_foreign_root_does_not(tmp_path, monkeypatch):
    monkeypatch.setenv("WTQRK_SELF_TEST", "0")
    det = {"payload": "https://x", "symbology": "VNBarcodeSymbologyQR", "confidence": 1.0,
           "boundingBox": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4}}
    doc = {"schema": wt.SCHEMA, "ok": True, "mode": "default", "compute": "auto",
           "report": {"imageDimensions": {"width": 10, "height": 10}, "mutationsTried": 1,
                      "detections": [det]}}
    exe = tmp_path / "wtqrk-scan"
    exe.write_text("#!/bin/sh\n")
    inp = tmp_path / "in.png"
    inp.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\0" * 32)
    eng = wt.WilliamTellsEngine(scan_bin=str(exe), sandbox=_Sandbox(json.dumps(doc).encode()))
    res = eng.detonate(inp, tmp_path, Limits())
    contract = ec.load_contract(CONTRACT_PATH)
    assert res.status == "ok"
    ec.assert_conforms(contract, res, tmp_path)
    # The checker is live: the same result missing a promised field is caught.
    for promised in ("budget_exhausted", "detections_found", "detections_truncated",
                     "payloads_truncated"):
        fields = {k: v for k, v in res.payload.fields.items() if k != promised}
        bad = dataclasses.replace(res, payload=Record(fields=fields))
        with pytest.raises(AssertionError, match=promised):
            ec.assert_conforms(contract, bad, tmp_path)
