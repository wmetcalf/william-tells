"""Every result the engine returns in these tests is held to its engine contract
(``blastbox-engine.toml`` at the repo root). The checker ships on blastbox's contract branch;
on a released blastbox without it the hook is a no-op and ``test_contract.py`` skips."""
from __future__ import annotations

from pathlib import Path

import pytest

from william_tells.blastbox_engine import WilliamTellsEngine

try:
    from blastbox.contract.engine_contract import assert_conforms, find_contract, load_contract
except ImportError:  # released blastbox: no contract checker yet
    CONTRACT = None
else:
    CONTRACT = load_contract(find_contract(Path(__file__).resolve().parents[2]))


def conform(result, outdir=None):
    """Assert ``result`` (a DetonationResult, sealed Envelope, or metadata.json dict) conforms."""
    if CONTRACT is not None and result is not None:
        assert_conforms(CONTRACT, result, outdir)
    return result


@pytest.fixture(autouse=True)
def _engine_results_conform(monkeypatch):
    if CONTRACT is None:
        return
    detonate, precheck = WilliamTellsEngine.detonate, WilliamTellsEngine.precheck

    def checked_detonate(self, input, outdir, limits):
        return conform(detonate(self, input, outdir, limits), outdir)

    def checked_precheck(self, limits):
        return conform(precheck(self, limits))

    monkeypatch.setattr(WilliamTellsEngine, "detonate", checked_detonate)
    monkeypatch.setattr(WilliamTellsEngine, "precheck", checked_precheck)
