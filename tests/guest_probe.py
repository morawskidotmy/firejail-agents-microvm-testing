#!/usr/bin/env python3
"""Small guest-side probe intended to be run inside the VM's inner Firejail."""

from __future__ import annotations

import json
from pathlib import Path


def main() -> int:
    checks = {
        "cwd": str(Path.cwd()),
        "home": str(Path.home()),
        "project_visible": Path.cwd().exists(),
        "ssh_visible": (Path.home() / ".ssh").exists(),
        "aws_visible": (Path.home() / ".aws").exists(),
        "dev_kvm_visible": Path("/dev/kvm").exists(),
        "run_user_bus_visible": Path(f"/run/user/{Path('/proc/self').stat().st_uid}/bus").exists(),
    }
    print(json.dumps(checks, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
