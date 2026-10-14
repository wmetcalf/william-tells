"""blastbox engine for William Tells QR Killer.

Each image is decoded by ``wtqrk-scan`` -- a one-shot Swift CLI around Apple Vision -- in its
own macOS sandbox (blastbox's ``seatbelt`` by default, or ``appsandbox``), with the GPU and the
Neural Engine granted and nothing else: no network, no home directory, a fresh scratch dir, and
read access to the one input file. The CLI prints one JSON document; this module treats that
output as **untrusted** (the process just parsed a hostile image) and validates every field
before mapping it onto a generic ``Record``.

Silent false negatives are the failure that matters. A sandbox that loses its Neural Engine
grant doesn't make Vision crash; it makes it find nothing, which reads like a clean verdict. So
the engine runs ``wtqrk-scan self-test`` (decode a freshly generated QR, on the ANE where the
hardware has one) under the same sandbox before trusting any "no detections" result, and
returns ``engine_error`` for every job while that self-test fails. ``warmup()`` runs it early,
but because ``http_agent`` treats a warmup failure as non-fatal, ``detonate()`` enforces it too.

Warm plan cache. Every sandboxed run starts with an empty HOME, so Vision would recompile its
Neural Engine plan on every image (~1.1 s/job vs ~0.15 s). The self-test -- a TRUSTED run on a
generated QR, never job input -- captures its HOME (``capture_home``) into a private seed dir,
and every scan gets a copy-on-write clone of it (``seed_home``). A job can modify its own
clone; nothing flows back, so one image cannot poison the next.

Operator configuration (worker env, never job params):
  WTQRK_SCAN_BIN        absolute path to wtqrk-scan (default: ``wtqrk-scan`` on PATH)
  WTQRK_SELF_TEST       ``0`` to skip the self-test gate (NOT recommended; also disables
                        the warm plan cache, which is built by the self-test)

Per-job params (forwarded by the dispatcher; allowlist them with
``BLASTBOX_ENGINE_WILLIAMTELLS_PARAM_KEYS=WTQRK_MODE,WTQRK_CONFIG``):
  WTQRK_MODE            ``default`` (~60 mutations, stop at first hit) or ``heavy`` (full sweep)
  WTQRK_CONFIG          JSON mutation config, same shape and limits as the web API's ``config``
"""
from __future__ import annotations

import json
import logging
import math
import os
import shutil
import tempfile
import threading
from pathlib import Path
from typing import Any

from blastbox.contract import Detection, Record, Warning
from blastbox.limits import Limits
from blastbox.worker.engine import DetonationResult
from blastbox.worker.sandbox import Mount, Sandbox, SandboxRequest, select_sandbox

_log = logging.getLogger("william_tells.blastbox_engine")

SCHEMA = "wtqrk.scan/1"
ENGINE_NAME = "williamtells"
ACCELERATORS = frozenset({"gpu", "ane"})

MAX_STDOUT_BYTES = 4 * 1024 * 1024
MAX_DETECTIONS = 256
MAX_PAYLOAD_CHARS = 4096
_CONFIG_KEYS = frozenset({
    "scales", "brightnessDeltas", "contrastDeltas", "blurRadii", "rotationDegrees",
    "sharpenIntensities",
})

# Labels the scanner may report as `inputType` (QRScannerEngine.inputMIMEs): it parses the
# input sandboxed, so a completed scan's `detected` comes from there; this host never parses XML.
INPUT_MIMES: dict[str, str] = {
    "png": "image/png", "jpeg": "image/jpeg", "gif": "image/gif", "tiff": "image/tiff",
    "bmp": "image/bmp", "webp": "image/webp", "heic": "image/heic", "heif": "image/heif",
    "pdf": "application/pdf", "svg": "image/svg+xml",
}

# Magic-number sniff for `detected` when the scanner didn't report a type (a failed scan).
_MAGIC: list[tuple[bytes, int, str, str]] = [
    (b"\x89PNG\r\n\x1a\n", 0, "png", "image/png"),
    (b"\xff\xd8\xff", 0, "jpeg", "image/jpeg"),
    (b"GIF87a", 0, "gif", "image/gif"),
    (b"GIF89a", 0, "gif", "image/gif"),
    (b"II*\x00", 0, "tiff", "image/tiff"),
    (b"MM\x00*", 0, "tiff", "image/tiff"),
    (b"BM", 0, "bmp", "image/bmp"),
    (b"%PDF-", 0, "pdf", "application/pdf"),
]


class SelfTestFailed(RuntimeError):
    """wtqrk-scan could not decode a known QR under the sandbox: results can't be trusted."""


def sniff(head: bytes) -> tuple[str, str]:
    for magic, off, label, mime in _MAGIC:
        if head[off:off + len(magic)] == magic:
            return label, mime
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp", "image/webp"
    if head[4:8] == b"ftyp" and head[8:12] in (b"heic", b"heix", b"heim", b"heis"):
        return "heic", "image/heic"
    if head[4:8] == b"ftyp" and head[8:12] in (b"mif1", b"msf1"):   # generic HEIF brands
        return "heif", "image/heif"
    return "unknown", "application/octet-stream"


def _validate_config(raw: str) -> str:
    """Parse WTQRK_CONFIG strictly; return canonical JSON. ValueError on anything odd."""
    cfg = json.loads(raw)
    if not isinstance(cfg, dict) or not set(cfg) <= _CONFIG_KEYS:
        raise ValueError(f"WTQRK_CONFIG must be an object with keys from {sorted(_CONFIG_KEYS)}")
    for key, values in cfg.items():
        if not isinstance(values, list) or len(values) > 10 or not all(
            isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
            for v in values
        ):
            raise ValueError(f"WTQRK_CONFIG.{key} must be a list of at most 10 finite numbers")
    return json.dumps(cfg, separators=(",", ":"))


def _num(v: Any, lo: float, hi: float) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise ValueError(f"not a finite number: {v!r}")
    if not lo <= v <= hi:
        raise ValueError(f"{v!r} outside [{lo}, {hi}]")
    return float(v)


def _int(v: Any, lo: int, hi: int) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
        raise ValueError(f"not an int in [{lo}, {hi}]: {v!r}")
    return v


def _str(v: Any, limit: int) -> tuple[str, bool]:
    if not isinstance(v, str):
        raise ValueError(f"not a string: {type(v).__name__}")
    return (v[:limit], len(v) > limit)


def parse_scan_output(stdout: bytes) -> tuple[dict[str, Any], list[Warning]]:
    """Validate wtqrk-scan's (untrusted) JSON. Returns the parsed doc + warnings.

    Raises ValueError for anything malformed. A compromised scanner can still LIE about what it
    found -- the sandbox bounds what it can reach, not what it says -- but it cannot get
    oversized, mistyped, or out-of-range data past this point.
    """
    if len(stdout) > MAX_STDOUT_BYTES:
        raise ValueError(f"scanner output exceeds {MAX_STDOUT_BYTES} bytes")
    doc = json.loads(stdout)
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        raise ValueError("scanner output has the wrong schema")
    input_type = doc.get("inputType")
    if input_type is not None and (not isinstance(input_type, str) or input_type not in INPUT_MIMES):
        raise ValueError(f"inputType must be one of {sorted(INPUT_MIMES)}")
    if doc.get("ok") is not True:
        return doc, []
    report = doc.get("report")
    if not isinstance(report, dict):
        raise ValueError("report missing")
    dims = report.get("imageDimensions") or {}
    warnings: list[Warning] = []
    raw_dets = report.get("detections")
    if not isinstance(raw_dets, list):
        raise ValueError("detections must be a list")
    if len(raw_dets) > MAX_DETECTIONS:
        warnings.append(Warning(code="detections_truncated",
                                message=f"kept {MAX_DETECTIONS} of {len(raw_dets)} detections"))
    dets = []
    for d in raw_dets[:MAX_DETECTIONS]:
        if not isinstance(d, dict):
            raise ValueError("detection must be an object")
        payload, cut = _str(d.get("payload"), MAX_PAYLOAD_CHARS)
        if cut:
            warnings.append(Warning(code="payload_truncated",
                                    message=f"a payload was cut to {MAX_PAYLOAD_CHARS} chars"))
        bb = d.get("boundingBox")
        if not isinstance(bb, dict):
            raise ValueError("boundingBox must be an object")
        dets.append({
            "payload": payload,
            "symbology": _str(d.get("symbology"), 64)[0],
            "confidence": _num(d.get("confidence"), 0.0, 1.0),
            # Vision boxes are normalized (origin bottom-left); mutations can push them slightly
            # outside [0, 1], so allow a margin rather than rejecting a real detection.
            "bbox_x": _num(bb.get("x"), -10.0, 10.0),
            "bbox_y": _num(bb.get("y"), -10.0, 10.0),
            "bbox_w": _num(bb.get("width"), 0.0, 10.0),
            "bbox_h": _num(bb.get("height"), 0.0, 10.0),
        })
    clean = {
        "ok": True,
        "mode": _str(doc.get("mode"), 16)[0],
        "compute": _str(doc.get("compute"), 16)[0],
        "image_width": _int(dims.get("width"), 1, 1 << 20),
        "image_height": _int(dims.get("height"), 1, 1 << 20),
        "mutations_tried": _int(report.get("mutationsTried"), 0, 10_000),
        "detections": dets,
        "input_type": input_type,
    }
    return clean, warnings


class WilliamTellsEngine:
    """Decode QR / barcodes with Apple Vision, one sandboxed ``wtqrk-scan`` per image."""

    name = ENGINE_NAME
    # Every untrusted parse runs in wtqrk-scan under select_sandbox(); this process only validates
    # its JSON. blastbox's macOS agent requires the declaration (there's no outer boundary there).
    sandboxed_parsing = True
    formats = frozenset({"png", "jpeg", "heic", "heif", "webp", "tiff", "gif", "bmp", "svg", "pdf"})

    # One self-test verdict per process (the agent is long-lived; a macOS update needs a
    # restart -- and a `blastbox macos doctor` run -- anyway).
    _self_test_lock = threading.Lock()
    _self_test_ok: bool | None = None
    _self_test_detail = ""
    _plan_cache: Path | None = None

    def __init__(self, *, scan_bin: str | None = None, sandbox: Sandbox | None = None) -> None:
        raw = scan_bin or os.environ.get("WTQRK_SCAN_BIN", "") or "wtqrk-scan"
        resolved = raw if os.sep in raw else shutil.which(raw)
        self._bin = Path(resolved) if resolved else None
        self._sandbox = sandbox
        self._self_test_enabled = os.environ.get("WTQRK_SELF_TEST", "1").strip() not in ("0", "false", "no")

    # ------------------------------------------------------------------
    def _sb(self) -> Sandbox:
        if self._sandbox is None:
            self._sandbox = select_sandbox()
        return self._sandbox

    def _require_bin(self) -> Path:
        if self._bin is None or not self._bin.is_file():
            raise FileNotFoundError(
                f"wtqrk-scan not found ({self._bin or 'not on PATH'}); "
                "build it with `swift build -c release` and set WTQRK_SCAN_BIN")
        return self._bin

    def self_test(self) -> tuple[bool, str]:
        """Run ``wtqrk-scan self-test`` in the sandbox; cache and return (ok, detail)."""
        cls = type(self)
        with cls._self_test_lock:
            if cls._self_test_ok is not None:
                return cls._self_test_ok, cls._self_test_detail
            exe = self._require_bin()
            # Private 0700 dir; only this trusted run ever writes it.
            cache = Path(tempfile.mkdtemp(prefix="wtqrk-plan-cache-"))
            r = self._sb().run(SandboxRequest(
                argv=[str(exe), "self-test"], accelerators=ACCELERATORS,
                limits=Limits(timeout_s=120), capture_home=cache))
            detail = (r.stdout + b"\n" + r.stderr).decode(errors="replace").strip()[-1500:]
            ok = r.exit_code == 0 and not r.killed
            if ok:
                try:
                    ok = json.loads(r.stdout).get("ok") is True
                except ValueError:
                    ok = False
            cls._self_test_ok, cls._self_test_detail = ok, detail
            cls._plan_cache = cache if ok and any(cache.iterdir()) else None
            (_log.info if ok else _log.error)(
                "wtqrk self-test %s under sandbox %s", "passed" if ok else "FAILED",
                getattr(self._sb(), "name", "?"))
            return ok, detail

    def warmup(self) -> None:
        if self._self_test_enabled:
            ok, detail = self.self_test()
            if not ok:
                raise SelfTestFailed(detail)

    # ------------------------------------------------------------------
    def detonate(self, input: Path, outdir: Path, limits: Limits) -> DetonationResult:
        with input.open("rb") as fh:
            head = fh.read(1024)
        label, mime = sniff(head)
        detected = Detection(label=label, mime=mime, confidence=1.0 if label != "unknown" else 0.0,
                             source=ENGINE_NAME)

        def error(code: str, message: str, status: str = "engine_error") -> DetonationResult:
            return DetonationResult(
                payload=Record(fields={"schema": SCHEMA, "error": code}),
                artifacts=[], detected=detected, status=status,  # type: ignore[arg-type]
                warnings=[Warning(code=code, message=message[:2000])])

        if self._self_test_enabled:
            ok, detail = self.self_test()
            if not ok:
                # Never let "found nothing" stand in for "couldn't look".
                return error("self_test_failed",
                             "scanner failed its known-QR self-test under the sandbox; "
                             "no result is trustworthy until `blastbox macos doctor` passes: "
                             + detail)

        mode = os.environ.get("WTQRK_MODE", "default").strip() or "default"
        if mode not in ("default", "heavy"):
            return error("bad_param", f"WTQRK_MODE must be default or heavy, not {mode[:32]!r}",
                         status="rejected")
        exe = self._require_bin()
        argv = [str(exe), "scan", str(input), "--max-bytes", str(limits.max_input_bytes)]
        if mode == "heavy":
            argv.append("--heavy")
        raw_cfg = os.environ.get("WTQRK_CONFIG", "").strip()
        if raw_cfg:
            try:
                argv += ["--config-json", _validate_config(raw_cfg)]
            except ValueError as exc:
                return error("bad_config", str(exc), status="rejected")

        r = self._sb().run(SandboxRequest(
            argv=argv, ro_mounts=[Mount(input, input)], accelerators=ACCELERATORS, limits=limits,
            seed_home=type(self)._plan_cache))
        if r.killed:
            return error("scanner_killed",
                         "scanner killed (timeout or memory limit): "
                         + r.stderr.decode(errors="replace")[-500:])
        try:
            doc, warnings = parse_scan_output(r.stdout)
        except ValueError as exc:
            return error("bad_scanner_output",
                         f"rc={r.exit_code}: {exc}; stderr: "
                         + r.stderr.decode(errors="replace")[-500:])

        if doc.get("ok") is not True:
            err = doc.get("error") if isinstance(doc.get("error"), dict) else {}
            code = str(err.get("code", "scan_failed"))[:64]
            msg = str(err.get("message", ""))[:2000]
            status = "rejected" if r.exit_code in (2, 3) else "engine_error"
            return error(code, msg, status=status)
        if r.exit_code != 0:
            # Printed success, then crashed or exited nonzero: not a cleanly finished scan.
            return error("scanner_failed",
                         f"scanner reported ok but exited rc={r.exit_code}; stderr: "
                         + r.stderr.decode(errors="replace")[-500:])

        if doc["input_type"]:
            detected = Detection(label=doc["input_type"], mime=INPUT_MIMES[doc["input_type"]],
                                 confidence=1.0, source=ENGINE_NAME)
        dets = doc["detections"]
        fields: dict[str, Any] = {
            "schema": SCHEMA,
            "mode": doc["mode"],
            "compute": doc["compute"],
            "image_width": doc["image_width"],
            "image_height": doc["image_height"],
            "mutations_tried": doc["mutations_tried"],
            "detection_count": len(dets),
            "payloads": [d["payload"] for d in dets],
            "detections": Record(fields={
                str(i): Record(fields=d) for i, d in enumerate(dets)
            }),
        }
        return DetonationResult(payload=Record(fields=fields), artifacts=[], detected=detected,
                                warnings=warnings)
