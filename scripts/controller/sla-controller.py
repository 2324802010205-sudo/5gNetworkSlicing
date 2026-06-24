#!/usr/bin/env python3
import argparse
import json
import math
import shlex
import subprocess
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MEASURE_SCRIPT = REPO_ROOT / "scripts" / "measure-urllc-sla.sh"
APPLY_POLICY_SCRIPT = REPO_ROOT / "scripts" / "apply-slice-policy.sh"
PUSH_METRICS_SCRIPT = REPO_ROOT / "scripts" / "push-slice-metrics.sh"
STATE_FILE = REPO_ROOT / "reports" / "controller-state.json"
CAPACITY_FILE = REPO_ROOT / "reports" / "capacity.env"
FALLBACK_ALLOCATIONS = {
    "dynamic-normal": (12, 3),
    "dynamic-urllc-priority": (10, 5),
}


def run_command(cmd, check=True):
    print("+ " + shlex.join(str(part) for part in cmd), flush=True)
    result = subprocess.run(
        [str(part) for part in cmd],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed with exit code {result.returncode}: {shlex.join(str(part) for part in cmd)}")
    return result


def parse_key_values(output):
    values = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip().upper()
        value = value.strip()
        if key:
            values[key] = value
    return values


def parse_float(value, default=math.nan):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def load_allocations():
    allocations = FALLBACK_ALLOCATIONS.copy()
    if not CAPACITY_FILE.exists():
        return allocations

    values = {}
    try:
        for raw_line in CAPACITY_FILE.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()

        normal = (
            float(values["DYNAMIC_NORMAL_EMBB_MBPS"]),
            float(values["DYNAMIC_NORMAL_URLLC_MBPS"]),
        )
        priority = (
            float(values["DYNAMIC_PRIORITY_EMBB_MBPS"]),
            float(values["DYNAMIC_PRIORITY_URLLC_MBPS"]),
        )
        if min(*normal, *priority) <= 0:
            raise ValueError("capacity values must be positive")
    except (OSError, KeyError, ValueError):
        print(f"WARNING: invalid {CAPACITY_FILE.relative_to(REPO_ROOT)}; using fallback allocations", file=sys.stderr)
        return allocations

    return {
        "dynamic-normal": normal,
        "dynamic-urllc-priority": priority,
    }


def load_state():
    if not STATE_FILE.exists():
        return {"profile": "dynamic-normal", "healthy_cycles": 0}
    try:
        with STATE_FILE.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {"profile": "dynamic-normal", "healthy_cycles": 0}

    profile = data.get("profile", "dynamic-normal")
    healthy_cycles = data.get("healthy_cycles", 0)
    try:
        healthy_cycles = int(healthy_cycles)
    except (TypeError, ValueError):
        healthy_cycles = 0
    return {"profile": profile, "healthy_cycles": max(0, healthy_cycles)}


def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with STATE_FILE.open("w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")


def measure_urllc():
    result = run_command(["bash", MEASURE_SCRIPT], check=False)

    values = parse_key_values(result.stdout)
    latency_ms = parse_float(values.get("URLLC_LATENCY_AVG_MS"))
    loss_percent = parse_float(values.get("URLLC_PACKET_LOSS_PERCENT"), default=100.0)

    return {
        "latency_ms": latency_ms,
        "loss_percent": loss_percent,
        "measure_exit_code": result.returncode,
    }


def is_violation(metrics, latency_threshold_ms, loss_threshold_percent):
    latency = metrics["latency_ms"]
    loss = metrics["loss_percent"]
    return (
        metrics["measure_exit_code"] != 0
        or math.isnan(latency)
        or math.isnan(loss)
        or latency > latency_threshold_ms
        or loss > loss_threshold_percent
    )


def is_healthy_for_release(metrics, latency_threshold_ms):
    latency = metrics["latency_ms"]
    loss = metrics["loss_percent"]
    return (
        metrics["measure_exit_code"] == 0
        and not math.isnan(latency)
        and not math.isnan(loss)
        and latency <= latency_threshold_ms
        and loss == 0
    )


def allocation_for(profile):
    return load_allocations().get(profile, FALLBACK_ALLOCATIONS["dynamic-normal"])


def decide_policy(metrics, args, state):
    violation = is_violation(metrics, args.latency_threshold_ms, args.loss_threshold_percent)
    previous_profile = state.get("profile", "dynamic-normal")
    healthy_cycles = int(state.get("healthy_cycles", 0))

    if violation:
        profile = "dynamic-urllc-priority"
        healthy_cycles = 0
        sla_violation = 1
    elif previous_profile == "dynamic-urllc-priority":
        if is_healthy_for_release(metrics, args.latency_threshold_ms):
            healthy_cycles += 1
        else:
            healthy_cycles = 0
        if healthy_cycles >= 2:
            profile = "dynamic-normal"
            healthy_cycles = 0
        else:
            profile = "dynamic-urllc-priority"
        sla_violation = 0
    else:
        profile = "dynamic-normal"
        healthy_cycles = 0
        sla_violation = 0

    embb_allocated_mbps, urllc_allocated_mbps = allocation_for(profile)
    next_state = {"profile": profile, "healthy_cycles": healthy_cycles}

    if profile == "dynamic-urllc-priority":
        return {
            "profile": profile,
            "embb_allocated_mbps": embb_allocated_mbps,
            "urllc_allocated_mbps": urllc_allocated_mbps,
            "sla_violation": sla_violation,
            "state": next_state,
        }

    return {
        "profile": profile,
        "embb_allocated_mbps": embb_allocated_mbps,
        "urllc_allocated_mbps": urllc_allocated_mbps,
        "sla_violation": sla_violation,
        "state": next_state,
    }


def run_iteration(args, iteration, total_iterations):
    print(f"\n=== SLA controller iteration {iteration}/{total_iterations} ===", flush=True)
    state = load_state()
    metrics = measure_urllc()
    decision = decide_policy(metrics, args, state)

    run_command(["bash", APPLY_POLICY_SCRIPT, "--profile", decision["profile"]])
    save_state(decision["state"])

    # TODO: parse URLLC jitter from iperf3 UDP output once scripts/test-urllc.sh
    # exposes stable machine-readable output. Ping loss is used for now.
    latency_text = "NaN" if math.isnan(metrics["latency_ms"]) else f"{metrics['latency_ms']:.3f}"
    loss_text = "NaN" if math.isnan(metrics["loss_percent"]) else f"{metrics['loss_percent']:.3f}"
    run_command(
        [
            "bash",
            PUSH_METRICS_SCRIPT,
            "--profile",
            decision["profile"],
            "--urllc-latency-ms",
            latency_text,
            "--urllc-jitter-ms",
            "0",
            "--urllc-loss-percent",
            loss_text,
            "--embb-allocated-mbps",
            str(decision["embb_allocated_mbps"]),
            "--urllc-allocated-mbps",
            str(decision["urllc_allocated_mbps"]),
            "--sla-violation",
            str(decision["sla_violation"]),
        ]
    )

    print(f"CONTROLLER_POLICY={decision['profile']}")
    print(f"URLLC_LATENCY_AVG_MS={latency_text}")
    print(f"URLLC_PACKET_LOSS_PERCENT={loss_text}")
    print(f"SLA_VIOLATION={decision['sla_violation']}")
    print(f"HEALTHY_CYCLES={decision['state']['healthy_cycles']}")
    print(f"STATE_FILE={STATE_FILE.relative_to(REPO_ROOT)}")


def main():
    parser = argparse.ArgumentParser(description="Closed-loop SLA controller for the 5G slicing lab")
    parser.add_argument("--once", action="store_true", help="Run exactly one measurement/apply/push iteration")
    parser.add_argument("--interval", type=int, default=10, help="Seconds between iterations")
    parser.add_argument("--iterations", type=int, default=1, help="Number of iterations; default is one, not infinite")
    parser.add_argument("--latency-threshold-ms", type=float, default=15.0)
    parser.add_argument("--loss-threshold-percent", type=float, default=0.0)
    args = parser.parse_args()

    iterations = 1 if args.once else args.iterations
    if iterations < 1:
        raise ValueError("--iterations must be at least 1")
    if args.interval < 1:
        raise ValueError("--interval must be at least 1")

    for index in range(1, iterations + 1):
        run_iteration(args, index, iterations)
        if index < iterations:
            time.sleep(args.interval)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
