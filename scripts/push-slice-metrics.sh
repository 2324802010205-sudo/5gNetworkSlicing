#!/bin/bash
set -euo pipefail

PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://localhost:9091}"
PROFILE=""
EMBB_MBPS="0"
URLLC_LATENCY_MS="NaN"
URLLC_JITTER_MS="0"
URLLC_LOSS_PERCENT="0"
EMBB_ALLOCATED_MBPS="0"
URLLC_ALLOCATED_MBPS="0"
SLA_VIOLATION="0"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/push-slice-metrics.sh \
    --profile dynamic-normal \
    --embb-mbps 12 \
    --urllc-latency-ms 10.2 \
    --urllc-jitter-ms 1.1 \
    --urllc-loss-percent 0 \
    --embb-allocated-mbps 12 \
    --urllc-allocated-mbps 3 \
    --sla-violation 0
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --embb-mbps) EMBB_MBPS="${2:-}"; shift 2 ;;
        --urllc-latency-ms) URLLC_LATENCY_MS="${2:-}"; shift 2 ;;
        --urllc-jitter-ms) URLLC_JITTER_MS="${2:-}"; shift 2 ;;
        --urllc-loss-percent) URLLC_LOSS_PERCENT="${2:-}"; shift 2 ;;
        --embb-allocated-mbps) EMBB_ALLOCATED_MBPS="${2:-}"; shift 2 ;;
        --urllc-allocated-mbps) URLLC_ALLOCATED_MBPS="${2:-}"; shift 2 ;;
        --sla-violation) SLA_VIOLATION="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$PROFILE" in
    no-policy|static|dynamic-normal|dynamic-urllc-priority) ;;
    "")
        echo "Missing required --profile" >&2
        usage >&2
        exit 2
        ;;
    *)
        echo "Unsupported profile: $PROFILE" >&2
        exit 2
        ;;
esac

{
    cat <<EOF
# HELP slice_throughput_mbps Slice throughput in Mbps.
# TYPE slice_throughput_mbps gauge
slice_throughput_mbps{slice="embb",profile="$PROFILE"} $EMBB_MBPS
# HELP slice_latency_ms Slice latency in milliseconds.
# TYPE slice_latency_ms gauge
slice_latency_ms{slice="urllc",profile="$PROFILE"} $URLLC_LATENCY_MS
# HELP slice_jitter_ms Slice jitter in milliseconds. TODO: parse from iperf3 UDP output when machine-readable URLLC test output is available.
# TYPE slice_jitter_ms gauge
slice_jitter_ms{slice="urllc",profile="$PROFILE"} $URLLC_JITTER_MS
# HELP slice_loss_percent Slice packet loss percent.
# TYPE slice_loss_percent gauge
slice_loss_percent{slice="urllc",profile="$PROFILE"} $URLLC_LOSS_PERCENT
# HELP slice_sla_violation Slice SLA violation flag, 1 for violation and 0 for healthy.
# TYPE slice_sla_violation gauge
slice_sla_violation{slice="urllc",profile="$PROFILE"} $SLA_VIOLATION
# HELP slice_allocated_mbps Allocated slice resource budget in Mbps.
# TYPE slice_allocated_mbps gauge
slice_allocated_mbps{slice="embb",profile="$PROFILE"} $EMBB_ALLOCATED_MBPS
slice_allocated_mbps{slice="urllc",profile="$PROFILE"} $URLLC_ALLOCATED_MBPS
# HELP slice_policy_active Active policy profile flag.
# TYPE slice_policy_active gauge
EOF
    for candidate in no-policy static dynamic-normal dynamic-urllc-priority; do
        if [ "$candidate" = "$PROFILE" ]; then
            echo "slice_policy_active{profile=\"$candidate\"} 1"
        else
            echo "slice_policy_active{profile=\"$candidate\"} 0"
        fi
    done
} | curl -fsS --data-binary @- "$PUSHGATEWAY_URL/metrics/job/slice-controller" >/dev/null

echo "Pushed slice metrics to $PUSHGATEWAY_URL for profile=$PROFILE"
