"""The blastbox ingress extension: UI wiring, the deep link, and the UI's output handling."""
from __future__ import annotations

import re
from pathlib import Path

import pytest
from fastapi import HTTPException

from william_tells import blastbox_ingress as bi

STATIC = Path(bi.__file__).parent / "static"


def test_extension_carries_ui_and_router():
    ext = bi.make_extension()
    assert ext.static_ui is not None
    assert Path(ext.static_ui.directory) == STATIC
    assert (STATIC / "index.html").is_file()
    for asset in ("app.js", "app.css", "logo.png"):
        assert (STATIC / "assets" / asset).is_file()
    assert bi.router in ext.routers


def test_serve_ui_off_leaves_api_only(monkeypatch):
    monkeypatch.setenv("WTQRK_SERVE_UI", "0")
    assert bi.make_extension().static_ui is None
    with pytest.raises(HTTPException) as exc:
        bi.spa_deeplink("abc")
    assert exc.value.status_code == 404


def test_deeplink_serves_the_ui_shell():
    assert any(getattr(r, "path", None) == "/jobs/{job_id}" for r in bi.router.routes)
    r = bi.spa_deeplink("8adcec31-7f82-41d7-84c6-7adf15574254")
    assert r.media_type == "text/html"
    assert '<script src="/assets/app.js">' in Path(r.path).read_text()


def test_ui_is_self_contained():
    # The ingress CSP is default-src 'self': no third-party fonts/scripts, no inline handlers.
    html = (STATIC / "index.html").read_text()
    css = (STATIC / "assets" / "app.css").read_text()
    assert "http://" not in html + css and "https://" not in html + css
    assert not re.search(r"\son[a-z]+=", html)


@pytest.mark.parametrize("sink", ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"])
def test_ui_never_renders_decoded_payloads_as_html(sink):
    # Payloads come out of hostile images; the UI must only ever set textContent.
    assert sink not in (STATIC / "assets" / "app.js").read_text()


def test_ui_sends_params_the_way_the_ingress_parses_them():
    # POST /v1/jobs takes repeated `params=KEY=VALUE` fields; a JSON blob is silently dropped.
    js = (STATIC / "assets" / "app.js").read_text()
    assert "fd.append('params', `WTQRK_MODE=${mode}`)" in js
    assert "JSON.stringify({ WTQRK" not in js

