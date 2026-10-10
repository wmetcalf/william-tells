"""William Tells product routes for the shared blastbox ingress.

Resolved by ``BLASTBOX_INGRESS_EXTENSION=william_tells.blastbox_ingress:make_extension``, the
same seam ClippyShot, RedTusk and titanarum use. The generic core already serves everything a
scan needs -- submit (``POST /v1/jobs``), status, the dispatcher-validated ``/metadata`` that
carries the decoded payloads, the signed ``/attestation`` -- so this module adds only the web UI
(at ``GET /`` + ``/assets``) and its ``/jobs/{id}`` deep link. No security logic of its own: the
routes inherit the app's auth middleware.

The old Vapor API (``/scan``, ``/upload``, ``/jobs/:id``) is NOT ported. It decodes in-process,
which is exactly what this path exists to avoid; the Vapor server remains available as a
standalone, unsandboxed mode.
"""
from __future__ import annotations

import os
from pathlib import Path

from blastbox.host.ingress.extension import IngressExtension, StaticUI
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

router = APIRouter()

_STATIC_DIR = Path(__file__).resolve().parent / "static"


@router.get("/jobs/{job_id}")
def spa_deeplink(job_id: str) -> FileResponse:
    """The UI shell for a shared/bookmarked ``/jobs/<id>`` URL (the page routes on its path).
    Distinct from ``/v1/jobs/{id}``, the JSON API."""
    index = _STATIC_DIR / "index.html"
    if not index.is_file() or not _serve_ui():
        raise HTTPException(status_code=404)
    return FileResponse(str(index), media_type="text/html")


def _serve_ui() -> bool:
    return os.environ.get("WTQRK_SERVE_UI", "1").strip().lower() not in {"0", "false", "no"}


def make_extension() -> IngressExtension:
    """Factory resolved by ``BLASTBOX_INGRESS_EXTENSION``. ``WTQRK_SERVE_UI=0`` leaves the
    ingress API-only (e.g. behind Loadout, which never uses the UI)."""
    static_ui = (StaticUI(directory=str(_STATIC_DIR))
                 if _serve_ui() and (_STATIC_DIR / "index.html").is_file() else None)
    return IngressExtension(routers=(router,), static_ui=static_ui)
