"""The host Dockerfile installs blastbox and a william-tells release in one pip command, so the
blastbox it pins must satisfy that release's blastbox floor. v0.2.1 is the last release whose
floor is 0.1.48; every later one carries this tree's floor (``pyproject.toml``)."""
from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "deploy/docker/Dockerfile.williamtells-host"
LAST_RELEASE_ON_OLD_FLOOR = (0, 2, 1)


def _ver(s: str) -> tuple[int, ...]:
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", s.strip())
    if not m:
        raise ValueError(f"not a release version: {s!r}")
    return tuple(int(x) for x in m.groups())


def _blastbox_floor() -> tuple[int, ...]:
    deps = tomllib.loads((ROOT / "python/pyproject.toml").read_text())["project"]["dependencies"]
    (spec,) = [d for d in deps if d.startswith("blastbox")]
    return _ver(spec.split(">=", 1)[1])


def _arg(text: str, name: str) -> str:
    m = re.search(rf"^ARG {name}=(\S+)$", text, re.M)
    if not m:
        raise ValueError(f"Dockerfile has no ARG {name}")
    return m.group(1)


def check_pins(text: str) -> None:
    wt, bb = _ver(_arg(text, "WILLIAMTELLS_REF")), _ver(_arg(text, "BLASTBOX_REF"))
    if wt > LAST_RELEASE_ON_OLD_FLOOR and bb < _blastbox_floor():
        raise AssertionError(
            f"WILLIAMTELLS_REF {wt} requires blastbox >= {_blastbox_floor()}, but BLASTBOX_REF is {bb}"
        )


def test_dockerfile_pins_are_installable_together():
    check_pins(DOCKERFILE.read_text())


def test_bumping_william_tells_alone_is_caught():
    text = DOCKERFILE.read_text()
    text = re.sub(r"^ARG WILLIAMTELLS_REF=\S+$", "ARG WILLIAMTELLS_REF=v0.2.2", text, flags=re.M)
    text = re.sub(r"^ARG BLASTBOX_REF=\S+$", "ARG BLASTBOX_REF=v0.1.48", text, flags=re.M)
    with pytest.raises(AssertionError, match="requires blastbox"):
        check_pins(text)
    check_pins(text.replace("ARG BLASTBOX_REF=v0.1.48", "ARG BLASTBOX_REF=v0.1.49"))
