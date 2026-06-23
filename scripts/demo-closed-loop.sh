#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

extract_metric() {
    local key="$1"
    awk -F= -v k="$key" '$1 == k {value = $2} END {if (value != "") print value}'
}

echo "Starting monitoring stack"
docker compose --profile monitoring up -d prometheus pushgateway grafana

echo "Starting traffic targets"
docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server

if [ -f scripts/verify-slice-path.sh ]; then
    echo "Running phase 1 slice path validation"
    if ! EMBB_PARALLEL="${EMBB_PARALLEL:-2}" bash scripts/verify-slice-path.sh; then
        echo "WARN: phase 1 validation did not pass; continuing to closed-loop demo"
    fi
fi

echo "Applying initial dynamic-normal policy"
bash scripts/apply-slice-policy.sh --profile dynamic-normal

echo "Measuring initial URLLC SLA"
set +e
MEASURE_OUTPUT=$(bash scripts/measure-urllc-sla.sh)
MEASURE_RC=$?
set -e
printf '%s\n' "$MEASURE_OUTPUT"

URLLC_LATENCY_MS=$(printf '%s\n' "$MEASURE_OUTPUT" | extract_metric URLLC_LATENCY_AVG_MS)
URLLC_LOSS_PERCENT=$(printf '%s\n' "$MEASURE_OUTPUT" | extract_metric URLLC_PACKET_LOSS_PERCENT)
URLLC_LATENCY_MS="${URLLC_LATENCY_MS:-NaN}"
URLLC_LOSS_PERCENT="${URLLC_LOSS_PERCENT:-100}"
SLA_VIOLATION="0"
if [ "$MEASURE_RC" -ne 0 ] || awk "BEGIN { exit !($URLLC_LOSS_PERCENT > 0) }"; then
    SLA_VIOLATION="1"
fi

bash scripts/push-slice-metrics.sh \
    --profile dynamic-normal \
    --embb-mbps 0 \
    --urllc-latency-ms "$URLLC_LATENCY_MS" \
    --urllc-jitter-ms 0 \
    --urllc-loss-percent "$URLLC_LOSS_PERCENT" \
    --embb-allocated-mbps 12 \
    --urllc-allocated-mbps 3 \
    --sla-violation "$SLA_VIOLATION"

echo "Running closed-loop controller"
python3 scripts/controller/sla-controller.py --interval 10 --iterations 6

echo
echo "Grafana: http://localhost:3000/d/5g-network-slicing/5g-network-slicing-resource-optimization"
echo "Prometheus: http://localhost:9090"
echo "Pushgateway: http://localhost:9091"
