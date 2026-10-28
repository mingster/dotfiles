"""Imported by python tests that change HOME. Python twin of asdf-pin.sh: pin the interpreters from
the repo's .tool-versions and the asdf data dir, so the shims keep working under a temp HOME.
Keeps any ASDF_* value that is already set."""
import os
from pathlib import Path

PINS = {"python": "ASDF_PYTHON_VERSION", "nodejs": "ASDF_NODEJS_VERSION"}


def pin():
    versions = Path(__file__).resolve().parents[3] / ".tool-versions"
    if versions.is_file():
        for line in versions.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] in PINS:
                os.environ.setdefault(PINS[parts[0]], parts[1])
    data = Path(os.environ.get("HOME", "")) / ".asdf"
    if data.is_dir():
        os.environ.setdefault("ASDF_DATA_DIR", str(data))
