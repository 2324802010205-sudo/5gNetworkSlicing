#!/usr/bin/env python3
import argparse
import csv
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


URLLC_LATENCY_SLA_MS = 20.0
URLLC_LOSS_SLA_PERCENT = 0.1
REPO_ROOT = Path(__file__).resolve().parents[2]
CAPACITY_FILE = REPO_ROOT / "reports" / "capacity.env"
FALLBACK_CAPACITY = {
    "SAFE_TOTAL_MBPS": 15.0,
    "DYNAMIC_NORMAL_EMBB_MBPS": 12.0,
    "DYNAMIC_NORMAL_URLLC_MBPS": 3.0,
    "DYNAMIC_PRIORITY_EMBB_MBPS": 10.0,
    "DYNAMIC_PRIORITY_URLLC_MBPS": 5.0,
}


def run(cmd, check=True):
    result = subprocess.run(cmd, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}\n{result.stderr.strip()}")
    return result.stdout


def docker_exec(container, command, check=True):
    return run(["docker", "exec", container, "sh", "-c", command], check=check)


def require_container(name):
    state = run(["docker", "inspect", "-f", "{{.State.Status}}", name], check=False).strip()
    if state != "running":
        raise RuntimeError(f"container {name} is not running")


def load_capacity():
    capacity = FALLBACK_CAPACITY.copy()
    if not CAPACITY_FILE.exists():
        return capacity

    try:
        for raw_line in CAPACITY_FILE.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key in capacity:
                capacity[key] = float(value)
        if min(capacity.values()) <= 0:
            raise ValueError("capacity values must be positive")
    except (OSError, ValueError):
        print(f"WARNING: invalid {CAPACITY_FILE}; using fallback capacity", file=sys.stderr)
        return FALLBACK_CAPACITY.copy()
    return capacity


def discover_urllc_target():
    output = docker_exec(
        "upf-urllc",
        "ip -4 -o addr show dev ogstun | awk '{print $4}' | cut -d/ -f1 | head -n1",
    )
    target = output.strip()
    if not target:
        raise RuntimeError("could not discover URLLC target from upf-urllc ogstun")
    return target


def ogstun_tx_bytes(container):
    output = docker_exec(container, "awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev")
    return int(output.strip() or "0")


def measure_urlcc_ping(target, count):
    output = docker_exec(
        "ue-urllc",
        f"ping -I uesimtun0 {target} -c {count} -i 0.2",
        check=False,
    )
    times = [float(value) for value in re.findall(r"time=([0-9.]+)", output)]
    loss_match = re.search(r"([0-9.]+)% packet loss", output)
    loss = float(loss_match.group(1)) if loss_match else 100.0
    if not times:
        return 9999.0, loss
    times.sort()
    p95_index = min(len(times) - 1, int(round(0.95 * (len(times) - 1))))
    return times[p95_index], loss


def delete_qdisc(container):
    docker_exec(container, "tc qdisc del dev ogstun root 2>/dev/null || true", check=False)


def apply_limit(container, mbps, prio, target_ms):
    mbps = max(1, int(mbps))
    command = f"""
tc qdisc replace dev ogstun root handle 1: htb default 10 r2q 10
tc class replace dev ogstun parent 1: classid 1:10 htb rate {mbps}mbit ceil {mbps}mbit burst 64k cburst 64k prio {prio}
tc qdisc replace dev ogstun parent 1:10 handle 10: fq_codel limit 256 target {target_ms}ms interval 100ms ecn
tc qdisc show dev ogstun >/dev/null
"""
    docker_exec(container, command)


def apply_mode(mode, embb_limit, urllc_limit):
    if mode == "no_slicing_baseline":
        delete_qdisc("upf-embb")
        delete_qdisc("upf-urllc")
        return 0, 0
    if mode in {"static_slicing", "dynamic_sla_slicing"}:
        apply_limit("upf-embb", embb_limit, prio=2, target_ms=5)
        apply_limit("upf-urllc", urllc_limit, prio=0, target_ms=1)
        return embb_limit, urllc_limit
    raise ValueError(mode)


def write_header(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "timestamp",
                "mode",
                "embb_mbps",
                "urllc_latency_ms",
                "urllc_loss_percent",
                "urllc_bw_limit",
                "embb_bw_limit",
            ]
        )


def append_row(path, row):
    with path.open("a", newline="") as handle:
        csv.writer(handle).writerow(row)


def main():
    parser = argparse.ArgumentParser(description="SLA-aware dynamic resource allocator for the 5G slicing lab")
    parser.add_argument(
        "--mode",
        choices=["no_slicing_baseline", "static_slicing", "dynamic_sla_slicing"],
        default="dynamic_sla_slicing",
    )
    parser.add_argument("--duration", type=int, default=120)
    parser.add_argument("--interval", type=int, default=3)
    parser.add_argument("--urllc-target", default="", help="Defaults to the discovered upf-urllc ogstun address")
    parser.add_argument("--ping-count", type=int, default=8)
    parser.add_argument("--total-mbps", type=int, default=None, help="Defaults to SAFE_TOTAL_MBPS from capacity.env")
    parser.add_argument("--static-embb-mbps", type=int, default=None)
    parser.add_argument("--static-urllc-mbps", type=int, default=None)
    parser.add_argument("--min-urllc-mbps", type=int, default=None)
    parser.add_argument("--max-urllc-mbps", type=int, default=None)
    parser.add_argument("--step-mbps", type=int, default=None)
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    for container in ["upf-embb", "upf-urllc", "ue-urllc"]:
        require_container(container)

    capacity = load_capacity()
    args.urllc_target = args.urllc_target or discover_urllc_target()
    args.total_mbps = args.total_mbps or max(
        2,
        round(capacity["SAFE_TOTAL_MBPS"]),
        round(capacity["DYNAMIC_NORMAL_EMBB_MBPS"] + capacity["DYNAMIC_NORMAL_URLLC_MBPS"]),
    )
    args.static_embb_mbps = args.static_embb_mbps or round(capacity["DYNAMIC_NORMAL_EMBB_MBPS"])
    args.static_urllc_mbps = args.static_urllc_mbps or round(capacity["DYNAMIC_NORMAL_URLLC_MBPS"])
    args.min_urllc_mbps = args.min_urllc_mbps or round(capacity["DYNAMIC_NORMAL_URLLC_MBPS"])
    args.max_urllc_mbps = args.max_urllc_mbps or max(
        args.min_urllc_mbps,
        min(args.total_mbps - 1, round(capacity["DYNAMIC_PRIORITY_URLLC_MBPS"])),
    )
    args.step_mbps = args.step_mbps or max(1, round(args.total_mbps * 0.1))

    if args.output:
        csv_path = Path(args.output)
    else:
        run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
        csv_path = Path("reports") / f"sla-dynamic-allocation-{args.mode}-{run_id}.csv"

    if args.mode == "no_slicing_baseline":
        embb_limit = 0
        urllc_limit = 0
    elif args.mode == "static_slicing":
        embb_limit = args.static_embb_mbps
        urllc_limit = args.static_urllc_mbps
    else:
        urllc_limit = max(args.min_urllc_mbps, min(args.max_urllc_mbps, args.static_urllc_mbps))
        embb_limit = max(1, args.total_mbps - urllc_limit)

    embb_limit, urllc_limit = apply_mode(args.mode, embb_limit, urllc_limit)
    write_header(csv_path)

    print(
        f"mode={args.mode} output={csv_path} urllc_target={args.urllc_target} "
        f"total_mbps={args.total_mbps}"
    )
    print("timestamp,mode,embb_mbps,urllc_latency_ms,urllc_loss_percent,urllc_bw_limit,embb_bw_limit")

    stable_cycles = 0
    previous_tx = ogstun_tx_bytes("upf-embb")
    end_time = time.time() + args.duration

    while time.time() < end_time:
        sample_start = time.time()
        time.sleep(args.interval)
        current_tx = ogstun_tx_bytes("upf-embb")
        elapsed = max(0.001, time.time() - sample_start)
        embb_mbps = max(0.0, (current_tx - previous_tx) * 8 / elapsed / 1_000_000)
        previous_tx = current_tx

        latency_ms, loss_percent = measure_urlcc_ping(args.urllc_target, args.ping_count)
        violation = latency_ms > URLLC_LATENCY_SLA_MS or loss_percent > URLLC_LOSS_SLA_PERCENT

        if args.mode == "dynamic_sla_slicing":
            if violation:
                stable_cycles = 0
                urllc_limit = min(args.max_urllc_mbps, urllc_limit + args.step_mbps)
                embb_limit = max(1, args.total_mbps - urllc_limit)
                apply_mode(args.mode, embb_limit, urllc_limit)
            else:
                stable_cycles += 1
                if stable_cycles >= 3 and urllc_limit > args.min_urllc_mbps:
                    urllc_limit = max(args.min_urllc_mbps, urllc_limit - args.step_mbps)
                    embb_limit = max(1, args.total_mbps - urllc_limit)
                    stable_cycles = 0
                    apply_mode(args.mode, embb_limit, urllc_limit)

        timestamp = datetime.now(timezone.utc).isoformat()
        row = [
            timestamp,
            args.mode,
            f"{embb_mbps:.3f}",
            f"{latency_ms:.3f}",
            f"{loss_percent:.3f}",
            urllc_limit,
            embb_limit,
        ]
        append_row(csv_path, row)
        print(",".join(map(str, row)), flush=True)

    print(f"CSV written: {csv_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
