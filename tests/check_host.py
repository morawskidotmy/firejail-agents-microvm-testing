#!/usr/bin/env python3
"""Check host readiness for VM-backed Firejail benchmark runs."""

from __future__ import annotations

import argparse
import grp
import json
import os
import shutil
import stat
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Check:
    name: str
    status: str
    detail: str


def project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_config(root: Path, config_path: Path | None) -> dict[str, Any]:
    path = config_path or root / "config.example.json"
    return json.loads(path.read_text())


def cpu_flags() -> set[str]:
    try:
        text = Path("/proc/cpuinfo").read_text()
    except OSError:
        return set()
    flags: set[str] = set()
    for line in text.splitlines():
        if line.startswith(("flags", "Features")):
            flags.update(line.partition(":")[2].split())
    return flags


def check_cpu_virtualization() -> Check:
    flags = cpu_flags()
    if "vmx" in flags:
        return Check("cpu_virtualization", "pass", "Intel VT-x flag vmx is visible")
    if "svm" in flags:
        return Check("cpu_virtualization", "pass", "AMD-V flag svm is visible")
    return Check(
        "cpu_virtualization",
        "fail",
        "neither vmx nor svm is visible; enable virtualization in firmware or outer VM",
    )


def check_kvm_device() -> Check:
    path = Path("/dev/kvm")
    if not path.exists():
        return Check("dev_kvm", "fail", "/dev/kvm does not exist")
    access = []
    if os.access(path, os.R_OK):
        access.append("read")
    if os.access(path, os.W_OK):
        access.append("write")
    if {"read", "write"}.issubset(access):
        return Check("dev_kvm", "pass", "/dev/kvm exists and is readable/writable")
    detail = f"/dev/kvm exists but access is only {','.join(access) or 'none'}"
    return Check("dev_kvm", "fail", detail)


def check_kvm_group() -> Check:
    path = Path("/dev/kvm")
    if not path.exists():
        return Check("kvm_group", "skip", "/dev/kvm is missing")
    device_stat = path.stat()
    group = group_name(device_stat.st_gid)
    if group in current_groups():
        return Check("kvm_group", "pass", f"current user is in {group}")
    permissions = stat.filemode(device_stat.st_mode)
    return Check(
        "kvm_group",
        "fail",
        f"current user is not in {group}; /dev/kvm permissions are {permissions}",
    )


def group_name(gid: int) -> str:
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return str(gid)


def current_groups() -> set[str]:
    return {group_name(gid) for gid in os.getgroups()}


def check_kvm_modules() -> list[Check]:
    checks = [module_check("kvm")]
    flags = cpu_flags()
    if "vmx" in flags:
        checks.append(module_check("kvm_intel"))
    elif "svm" in flags:
        checks.append(module_check("kvm_amd"))
    else:
        checks.append(Check("kvm_vendor_module", "skip", "CPU virtualization vendor is unknown"))
    return checks


def module_check(name: str) -> Check:
    if Path(f"/sys/module/{name}").exists():
        return Check(f"module:{name}", "pass", f"{name} kernel module is loaded")
    return Check(f"module:{name}", "fail", f"{name} kernel module is not loaded")


def check_binary(name: str, binary: str) -> Check:
    path = shutil.which(binary)
    if path is None:
        return Check(f"binary:{name}", "fail", f"{binary} was not found on PATH")
    return Check(f"binary:{name}", "pass", path)


def binary_checks(config: dict[str, Any]) -> list[Check]:
    checks = [check_binary("firejail", "firejail")]
    for name in ("firecracker", "kvmtool", "crosvm"):
        configured = config.get(name, {}).get("binary") or name
        checks.append(check_binary(name, configured))
    return checks


def image_checks(config: dict[str, Any], explicit_config: bool) -> list[Check]:
    checks = []
    for name in ("firecracker", "kvmtool", "crosvm"):
        section = config.get(name, {})
        checks.extend(
            image_check(name, key, section.get(key), explicit_config)
            for key in ("kernel_image", "rootfs_image")
        )
    return checks


def image_check(name: str, key: str, value: str | None, explicit_config: bool) -> Check:
    check_name = f"image:{name}:{key}"
    if not value:
        status = "fail" if explicit_config else "skip"
        return Check(check_name, status, f"{key} is not configured")
    path = Path(value).expanduser()
    if path.exists():
        return Check(check_name, "pass", str(path))
    return Check(check_name, "fail", f"configured path does not exist: {path}")


def run_checks(config: dict[str, Any], explicit_config: bool) -> list[Check]:
    checks = [check_cpu_virtualization(), check_kvm_device(), check_kvm_group()]
    checks.extend(check_kvm_modules())
    checks.extend(binary_checks(config))
    checks.extend(image_checks(config, explicit_config))
    return checks


def print_text(checks: list[Check]) -> None:
    print("# Host Readiness")
    print()
    for check in checks:
        print(f"- `{check.status}` {check.name}: {check.detail}")
    print()
    print(summary_line(checks))


def summary_line(checks: list[Check]) -> str:
    counts = {status: sum(1 for check in checks if check.status == status) for status in statuses()}
    return "Summary: " + " ".join(f"{status}={counts[status]}" for status in statuses())


def statuses() -> tuple[str, ...]:
    return ("pass", "fail", "skip")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="Path to config JSON with image paths")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = project_root()
    checks = run_checks(load_config(root, args.config), explicit_config=args.config is not None)
    if args.json:
        print(json.dumps([asdict(check) for check in checks], indent=2, sort_keys=True))
    else:
        print_text(checks)
    return 1 if any(check.status == "fail" for check in checks) else 0


if __name__ == "__main__":
    raise SystemExit(main())
