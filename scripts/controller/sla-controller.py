#!/usr/bin/env python3
import argparse
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


def read_embb_tx_bytes():
    result = subprocess.run(
        [
            "docker",
            "exec",
            "upf-embb",
            "sh",
            "-c",
            "awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev",
        ],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip() or "0")
    except ValueError:
        return None


def measure_urllc_and_embb():
    before_bytes = read_embb_tx_bytes()
    started = time.monotonic()
    result = run_command(["bash", MEASURE_SCRIPT], check=False)
    elapsed = max(0.001, time.monotonic() - started)
    after_bytes = read_embb_tx_bytes()

    values = parse_key_values(result.stdout)
    latency_ms = parse_float(values.get("URLLC_LATENCY_AVG_MS"))
    loss_percent = parse_float(values.get("URLLC_PACKET_LOSS_PERCENT"), default=100.0)

    embb_mbps = 0.0
    if before_bytes is not None and after_bytes is not None and after_bytes >= before_bytes:
        embb_mbps = (after_bytes - before_bytes) * 8 / elapsed / 1_000_000

    return {
        "latency_ms": latency_ms,
        "loss_percent": loss_percent,
        "embb_mbps": embb_mbps,
        "measure_exit_code": result.returncode,
    }


def decide_policy(metrics, latency_threshold_ms, loss_threshold_percent):
    latency = metrics["latency_ms"]
    loss = metrics["loss_percent"]
    violation = (
        metrics["measure_exit_code"] != 0
        or math.isnan(latency)
        or math.isnan(loss)
        or latency > latency_threshold_ms
        or loss > loss_threshold_percent
    )

    if violation:
        return {
            "profile": "dynamic-urllc-priority",
            "embb_allocated_mbps": 10,
            "urllc_allocated_mbps": 5,
            "sla_violation": 1,
        }

    return {
        "profile": "dynamic-normal",
        "embb_allocated_mbps": 12,
        "urllc_allocated_mbps": 3,
        "sla_violation": 0,
    }


def run_iteration(args, iteration, total_iterations):
    print(f"\n=== SLA controller iteration {iteration}/{total_iterations} ===", flush=True)
    metrics = measure_urllc_and_embb()
    decision = decide_policy(metrics, args.latency_threshold_ms, args.loss_threshold_percent)

    run_command(["bash", APPLY_POLICY_SCRIPT, "--profile", decision["profile"]])

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
            "--embb-mbps",
            f"{metrics['embb_mbps']:.3f}",
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
    print(f"EMBB_THROUGHPUT_MBPS={metrics['embb_mbps']:.3f}")
    print(f"SLA_VIOLATION={decision['sla_violation']}")


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
