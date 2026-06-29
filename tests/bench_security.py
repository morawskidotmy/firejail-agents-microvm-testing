#!/usr/bin/env python3
"""Benchmark and probe Firejail-only versus VM-plus-Firejail stacks.

The probes are defensive checks. They do not exploit vulnerabilities; they test
whether sensitive host paths and privileged operations are visible from each
configured sandbox layer.
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import shutil
import subprocess
import time
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

CLOCK_TICKS_PER_SECOND = os.sysconf(os.sysconf_names["SC_CLK_TCK"])


@dataclass(frozen=True)
class Stack:
    name: str
    mode: str
    profile: Path
    binary_key: str | None = None
    default_binary: str | None = None


@dataclass(frozen=True)
class ProcessMeasurement:
    pid: int
    command: str
    max_rss_kib: int
    cpu_ms: int
    avg_cpu_percent: float
    samples: int


@dataclass
class ProcessState:
    command: str
    first_cpu_ticks: int
    last_cpu_ticks: int
    max_rss_kib: int
    samples: int = 0


@dataclass(frozen=True)
class MonitorResult:
    max_tree_rss_kib: int
    max_processes: int
    timed_out: bool
    observed_ms: int
    processes: list[ProcessMeasurement]


@dataclass(frozen=True)
class Measurement:
    returncode: int | None
    timed_out: bool
    wall_ms: int
    user_cpu_ms: int
    system_cpu_ms: int
    max_rss_kib: int
    max_processes: int
    processes: list[ProcessMeasurement]
    stdout_tail: str
    stderr_tail: str


@dataclass(frozen=True)
class ProbeResult:
    name: str
    status: str
    detail: str
    measurement: Measurement | None = None


@dataclass(frozen=True)
class Fixtures:
    project_file: Path
    sibling_file: Path | None
    home_secret: Path | None


def project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_config(root: Path, config_path: Path | None) -> dict[str, Any]:
    path = config_path or root / "config.example.json"
    return json.loads(path.read_text())


def stacks(root: Path) -> list[Stack]:
    return [
        Stack(
            "firejail-only",
            "baseline",
            root / "baseline-profiles/firejail-only-code-agent.profile",
        ),
        Stack(
            "firecracker",
            "layered",
            root / "host-profiles/firecracker-host.profile",
            "firecracker",
            "firecracker",
        ),
        Stack(
            "kvmtool",
            "layered",
            root / "host-profiles/kvmtool-host.profile",
            "kvmtool",
            "lkvm",
        ),
        Stack(
            "crosvm",
            "layered",
            root / "host-profiles/crosvm-host.profile",
            "crosvm",
            "crosvm",
        ),
    ]


def make_fixtures(root: Path) -> Fixtures:
    project_file = root / "fixtures/project-visible.txt"
    project_file.write_text("project-visible\n")
    token = f"{os.getpid()}-{int(time.time())}"
    sibling_file = create_file(root.parent / f".vm-firejail-lab-sibling-{token}")
    home_secret = create_file(Path.home() / f".vm-firejail-lab-secret-{token}")
    return Fixtures(project_file, sibling_file, home_secret)


def create_file(path: Path) -> Path | None:
    try:
        path.write_text("sandbox-canary\n")
    except OSError:
        return None
    return path


def cleanup_fixtures(fixtures: Fixtures) -> None:
    for path in (fixtures.sibling_file, fixtures.home_secret):
        if path is not None:
            path.unlink(missing_ok=True)


def firejail_command(profile: Path, root: Path, inner: list[str]) -> list[str]:
    return [
        "firejail",
        "--quiet",
        f"--profile={profile}",
        f"--whitelist={root}",
        "--",
        *inner,
    ]


def run_measured(
    command: list[str], timeout: int, env: dict[str, str] | None = None
) -> Measurement:
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.perf_counter()
    proc = subprocess.Popen(
        command,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    monitor = monitor_process(proc, timeout)
    stdout, stderr = finish_process(proc, monitor.timed_out)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return Measurement(
        returncode=proc.returncode,
        timed_out=monitor.timed_out,
        wall_ms=round((time.perf_counter() - started) * 1000),
        user_cpu_ms=round((after.ru_utime - before.ru_utime) * 1000),
        system_cpu_ms=round((after.ru_stime - before.ru_stime) * 1000),
        max_rss_kib=monitor.max_tree_rss_kib,
        max_processes=monitor.max_processes,
        processes=monitor.processes,
        stdout_tail=tail(stdout),
        stderr_tail=tail(stderr),
    )


def monitor_process(proc: subprocess.Popen[str], timeout: int) -> MonitorResult:
    started = time.perf_counter()
    deadline = time.monotonic() + timeout
    max_rss = 0
    max_processes = 0
    states: dict[int, ProcessState] = {}
    timed_out = False
    while proc.poll() is None:
        pids = process_tree(proc.pid)
        max_processes = max(max_processes, len(pids))
        max_rss = max(max_rss, sample_processes(pids, states))
        if time.monotonic() > deadline:
            kill_process_group(proc)
            timed_out = True
            break
        time.sleep(0.02)
    observed_ms = round((time.perf_counter() - started) * 1000)
    return MonitorResult(
        max_tree_rss_kib=max_rss,
        max_processes=max_processes,
        timed_out=timed_out,
        observed_ms=observed_ms,
        processes=process_measurements(states, observed_ms),
    )


def finish_process(proc: subprocess.Popen[str], timed_out: bool) -> tuple[str, str]:
    if timed_out:
        proc.wait(timeout=2)
    return proc.communicate(timeout=2)


def kill_process_group(proc: subprocess.Popen[str]) -> None:
    try:
        os.killpg(proc.pid, 15)
        time.sleep(0.1)
        if proc.poll() is None:
            os.killpg(proc.pid, 9)
    except ProcessLookupError:
        return


def process_tree(root_pid: int) -> set[int]:
    seen = {root_pid}
    changed = True
    while changed:
        changed = add_child_processes(seen)
    return seen


def add_child_processes(seen: set[int]) -> bool:
    changed = False
    seen_names = {str(pid) for pid in seen}
    for proc_dir in Path("/proc").iterdir():
        if proc_dir.name.isdigit() and parent_pid(proc_dir) in seen:
            changed = proc_dir.name not in seen_names or changed
            seen.add(int(proc_dir.name))
    return changed


def parent_pid(proc_dir: Path) -> int | None:
    try:
        stat = (proc_dir / "stat").read_text()
    except OSError:
        return None
    close = stat.rfind(")")
    fields = stat[close + 2 :].split()
    if len(fields) < 2:
        return None
    return int(fields[1])


def read_rss(pid: int) -> int:
    try:
        lines = Path(f"/proc/{pid}/status").read_text().splitlines()
    except OSError:
        return 0
    return next((int(line.split()[1]) for line in lines if line.startswith("VmRSS:")), 0)


def sample_processes(pids: set[int], states: dict[int, ProcessState]) -> int:
    total_rss = 0
    for pid in pids:
        metrics = read_proc_metrics(pid)
        if metrics is None:
            continue
        rss_kib, cpu_ticks, command = metrics
        total_rss += rss_kib
        update_process_state(states, pid, command, rss_kib, cpu_ticks)
    return total_rss


def read_proc_metrics(pid: int) -> tuple[int, int, str] | None:
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    fields = stat_after_command(stat)
    if len(fields) < 13:
        return None
    cpu_ticks = int(fields[11]) + int(fields[12])
    return read_rss(pid), cpu_ticks, read_command(pid)


def stat_after_command(stat: str) -> list[str]:
    close = stat.rfind(")")
    return stat[close + 2 :].split()


def read_command(pid: int) -> str:
    try:
        command = Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return str(pid)
    return command or str(pid)


def update_process_state(
    states: dict[int, ProcessState], pid: int, command: str, rss_kib: int, cpu_ticks: int
) -> None:
    state = states.get(pid)
    if state is None:
        states[pid] = ProcessState(command, cpu_ticks, cpu_ticks, rss_kib, 1)
        return
    state.command = command
    state.last_cpu_ticks = cpu_ticks
    state.max_rss_kib = max(state.max_rss_kib, rss_kib)
    state.samples += 1


def process_measurements(
    states: dict[int, ProcessState], observed_ms: int
) -> list[ProcessMeasurement]:
    measurements = [process_measurement(pid, state, observed_ms) for pid, state in states.items()]
    return sorted(measurements, key=lambda item: (item.cpu_ms, item.max_rss_kib), reverse=True)


def process_measurement(pid: int, state: ProcessState, observed_ms: int) -> ProcessMeasurement:
    cpu_ms = round((state.last_cpu_ticks - state.first_cpu_ticks) * 1000 / CLOCK_TICKS_PER_SECOND)
    avg_cpu_percent = round(cpu_ms / max(observed_ms, 1) * 100, 2)
    return ProcessMeasurement(
        pid=pid,
        command=state.command,
        max_rss_kib=state.max_rss_kib,
        cpu_ms=cpu_ms,
        avg_cpu_percent=avg_cpu_percent,
        samples=state.samples,
    )


def tail(text: str, limit: int = 1000) -> str:
    return text[-limit:]


def profile_parse_probe(stack: Stack, timeout: int) -> ProbeResult:
    command = ["firejail", "--quiet", f"--profile={stack.profile}", "/bin/true"]
    result = run_measured(command, timeout)
    if result.returncode == 0:
        return ProbeResult(
            "profile_parse",
            "pass",
            "profile parsed and executed /bin/true",
            result,
        )
    detail = result.stderr_tail or "profile parse failed"
    return ProbeResult("profile_parse", "fail", detail, result)


def startup_probe(stack: Stack, root: Path, timeout: int) -> ProbeResult:
    result = run_measured(firejail_command(stack.profile, root, ["/bin/true"]), timeout)
    if result.returncode == 0:
        return ProbeResult("sandbox_startup", "pass", "sandbox launched /bin/true", result)
    detail = result.stderr_tail or "sandbox launch failed"
    return ProbeResult("sandbox_startup", "fail", detail, result)


def resource_probe(stack: Stack, root: Path, timeout: int) -> ProbeResult:
    script = """
import time
buf = bytearray(32 * 1024 * 1024)
deadline = time.perf_counter() + 0.75
value = 0
while time.perf_counter() < deadline:
    value += sum(range(1000))
print(len(buf), value)
""".strip()
    command = firejail_command(stack.profile, root, ["python3", "-c", script])
    result = run_measured(command, timeout)
    if result.returncode == 0:
        return ProbeResult(
            "resource_workload",
            "pass",
            "synthetic CPU and 32MiB allocation workload completed",
            result,
        )
    detail = result.stderr_tail or "synthetic workload failed"
    return ProbeResult("resource_workload", "fail", detail, result)


def visibility_probe(
    stack: Stack, root: Path, path: Path, expected: str, timeout: int
) -> ProbeResult:
    if not path.exists():
        return ProbeResult(f"visibility:{path}", "skip", "probe path does not exist")
    env = os.environ.copy()
    env["PROBE_PATH"] = str(path)
    command = firejail_command(
        stack.profile,
        root,
        ["/bin/sh", "-c", 'test -e "$PROBE_PATH" && test -r "$PROBE_PATH"'],
    )
    result = run_measured(command, timeout, env)
    visible = result.returncode == 0
    status = permission_status(visible, expected)
    detail = f"visible={visible}, expected={expected}"
    return ProbeResult(f"visibility:{path}", status, detail, result)


def permission_status(visible: bool, expected: str) -> str:
    if expected == "visible":
        return "pass" if visible else "fail"
    return "fail" if visible else "pass"


def action_probe(stack: Stack, root: Path, name: str, script: str, timeout: int) -> ProbeResult:
    result = run_measured(firejail_command(stack.profile, root, ["/bin/sh", "-c", script]), timeout)
    if result.returncode == 0:
        return ProbeResult(f"blocked_action:{name}", "fail", "privileged action succeeded", result)
    return ProbeResult(f"blocked_action:{name}", "pass", "privileged action was blocked", result)


def binary_probe(stack: Stack, config: dict[str, Any], root: Path, timeout: int) -> ProbeResult:
    if stack.binary_key is None:
        return ProbeResult("vmm_binary", "skip", "baseline has no VMM binary")
    configured = config.get(stack.binary_key, {}).get("binary", stack.default_binary)
    binary = shutil.which(configured or stack.default_binary or "")
    if binary is None and stack.name == "kvmtool":
        binary = shutil.which("kvmtool")
    if binary is None:
        return ProbeResult("vmm_binary", "skip", f"{configured} not found on PATH")
    result = run_measured(firejail_command(stack.profile, root, [binary, "--help"]), timeout)
    if result.returncode in {0, 1, 2} or usage_exit(result):
        return ProbeResult("vmm_binary", "pass", f"{binary} invoked under host Firejail", result)
    return ProbeResult("vmm_binary", "fail", result.stderr_tail or "VMM probe failed", result)


def usage_exit(result: Measurement) -> bool:
    return result.returncode == 22 and "usage:" in result.stdout_tail.lower()


def boot_probe(stack: Stack, config: dict[str, Any]) -> ProbeResult:
    if stack.binary_key is None:
        return ProbeResult("vm_boot", "skip", "baseline has no VM boot step")
    section = config.get(stack.binary_key, {})
    kernel = Path(section.get("kernel_image") or "")
    rootfs = Path(section.get("rootfs_image") or "")
    if not kernel.exists() or not rootfs.exists():
        return ProbeResult("vm_boot", "skip", "kernel_image/rootfs_image not configured or missing")
    return ProbeResult("vm_boot", "skip", "boot automation is intentionally runner-driven")


def kvm_probe(stack: Stack, root: Path, timeout: int) -> ProbeResult:
    path = Path("/dev/kvm")
    if not path.exists():
        return ProbeResult("visibility:/dev/kvm", "skip", "/dev/kvm does not exist on this host")
    expected = "blocked" if stack.mode == "baseline" else "visible"
    return visibility_probe(stack, root, path, expected, timeout)


def raw_disk_probe(stack: Stack, root: Path, timeout: int) -> ProbeResult:
    candidates = [Path("/dev/sda"), Path("/dev/nvme0n1"), Path("/dev/vda")]
    disk = next((path for path in candidates if path.exists()), None)
    if disk is None:
        return ProbeResult("visibility:raw_disk", "skip", "no common raw disk device found")
    return visibility_probe(stack, root, disk, "blocked", timeout)


def run_stack(
    stack: Stack, root: Path, config: dict[str, Any], fixtures: Fixtures
) -> dict[str, Any]:
    timeout = int(config.get("timeout_seconds", 6))
    probes = [
        profile_parse_probe(stack, timeout),
        startup_probe(stack, root, timeout),
        resource_probe(stack, root, timeout),
    ]
    probes.extend(permission_probes(stack, root, fixtures, timeout))
    probes.extend(action_probes(stack, root, timeout))
    probes.extend([binary_probe(stack, config, root, timeout), boot_probe(stack, config)])
    return {
        "name": stack.name,
        "mode": stack.mode,
        "profile": str(stack.profile),
        "probes": [probe_to_dict(probe) for probe in probes],
        "summary": summarize(probes),
    }


def permission_probes(
    stack: Stack, root: Path, fixtures: Fixtures, timeout: int
) -> list[ProbeResult]:
    probes = [visibility_probe(stack, root, fixtures.project_file, "visible", timeout)]
    probes.extend(
        visibility_probe(stack, root, path, "blocked", timeout)
        for path in (fixtures.sibling_file, fixtures.home_secret)
        if path is not None
    )
    uid = os.getuid()
    probes.extend(
        [
            visibility_probe(stack, root, Path(f"/run/user/{uid}/bus"), "blocked", timeout),
            visibility_probe(stack, root, Path("/var/run/docker.sock"), "blocked", timeout),
            kvm_probe(stack, root, timeout),
            raw_disk_probe(stack, root, timeout),
        ]
    )
    return probes


def action_probes(stack: Stack, root: Path, timeout: int) -> list[ProbeResult]:
    mount_script = (
        "mkdir -p /tmp/vm-firejail-mount-probe && mount -t tmpfs tmpfs /tmp/vm-firejail-mount-probe"
    )
    unshare_script = "command -v unshare >/dev/null && unshare -Ur true"
    return [
        action_probe(
            stack,
            root,
            "mount_tmpfs",
            mount_script,
            timeout,
        ),
        action_probe(stack, root, "unshare_userns", unshare_script, timeout),
    ]


def probe_to_dict(probe: ProbeResult) -> dict[str, Any]:
    data = asdict(probe)
    if probe.measurement is not None:
        data["measurement"] = asdict(probe.measurement)
    return data


def summarize(probes: list[ProbeResult]) -> dict[str, int]:
    return {
        status: sum(1 for probe in probes if probe.status == status)
        for status in ("pass", "fail", "skip")
    }


def write_outputs(root: Path, payload: dict[str, Any]) -> tuple[Path, Path]:
    results_dir = root / "results"
    results_dir.mkdir(exist_ok=True)
    json_path = results_dir / "latest.json"
    md_path = results_dir / "latest.md"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    md_path.write_text(markdown_report(payload))
    return json_path, md_path


def markdown_report(payload: dict[str, Any]) -> str:
    lines = ["# vm-firejail-lab Results", "", f"Generated: {payload['generated_at']}", ""]
    for result in payload["stacks"]:
        summary = result["summary"]
        lines.extend(
            [
                f"## {result['name']}",
                "",
                f"Mode: `{result['mode']}`",
                f"Summary: pass={summary['pass']} fail={summary['fail']} skip={summary['skip']}",
                "",
            ]
        )
        lines.extend(probe_lines(result["probes"]))
    lines.extend(comparison_lines(payload))
    return "\n".join(lines) + "\n"


def probe_lines(probes: list[dict[str, Any]]) -> list[str]:
    lines = [probe_line(probe) for probe in probes]
    lines.append("")
    return lines


def probe_line(probe: dict[str, Any]) -> str:
    line = f"- `{probe['status']}` {probe['name']}: {probe['detail']}"
    measurement = probe.get("measurement")
    if measurement is None:
        return line
    line += measurement_summary(measurement)
    top_processes = process_summary(measurement.get("processes", []))
    if top_processes:
        line += f"; top_processes={top_processes}"
    return line


def measurement_summary(measurement: dict[str, Any]) -> str:
    total_cpu = measurement["user_cpu_ms"] + measurement["system_cpu_ms"]
    return (
        f" (wall_ms={measurement['wall_ms']}, cpu_ms={total_cpu}, "
        f"max_rss_kib={measurement['max_rss_kib']}, "
        f"max_processes={measurement['max_processes']})"
    )


def process_summary(processes: list[dict[str, Any]]) -> str:
    summaries = [
        (
            f"{proc['command']}[{proc['pid']}]:rss={proc['max_rss_kib']}KiB,"
            f"cpu={proc['cpu_ms']}ms,avg={proc['avg_cpu_percent']}%"
        )
        for proc in processes[:3]
    ]
    return " | ".join(summaries)


def comparison_lines(payload: dict[str, Any]) -> list[str]:
    baseline = next(item for item in payload["stacks"] if item["mode"] == "baseline")
    layered = [item for item in payload["stacks"] if item["mode"] == "layered"]
    layered_failures = sum(item["summary"]["fail"] for item in layered)
    return [
        "## Comparison",
        "",
        f"Firejail-only failed probes: {baseline['summary']['fail']}.",
        f"Layered stack failed probes: {layered_failures} total across "
        f"{len(layered)} VMM profiles.",
        "Firejail-only is lighter and does not expose /dev/kvm, but a sandbox escape "
        "reaches the host user session directly.",
        "VM-plus-Firejail adds a guest kernel boundary and a guest Firejail layer, "
        "but needs VMM binaries, guest images, and /dev/kvm exposure to the "
        "host-side VMM process.",
        "Performance boot overhead could not be measured unless the VMM binary plus "
        "kernel/rootfs paths are configured.",
        "",
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="Path to config JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = project_root()
    config = load_config(root, args.config)
    fixtures = make_fixtures(root)
    try:
        payload = {
            "generated_at": datetime.now(UTC).isoformat(),
            "root": str(root),
            "firejail": shutil.which("firejail"),
            "dev_kvm_exists": Path("/dev/kvm").exists(),
            "stacks": [run_stack(stack, root, config, fixtures) for stack in stacks(root)],
        }
        json_path, md_path = write_outputs(root, payload)
    finally:
        cleanup_fixtures(fixtures)
    print(f"wrote {json_path}")
    print(f"wrote {md_path}")
    return 1 if any_failed(payload) else 0


def any_failed(payload: dict[str, Any]) -> bool:
    return any(stack["summary"]["fail"] for stack in payload["stacks"])


if __name__ == "__main__":
    raise SystemExit(main())
