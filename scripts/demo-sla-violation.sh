#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LATENCY_THRESHOLD_MS="${LATENCY_THRESHOLD_MS:-15}"

extract_metric() {
    local key="$1"
    awk -F= -v k="$key" '$1 == k {value = $2} END {if (value != "") print value}'
}

is_sla_violation() {
    local latency="$1"
    local loss="$2"

    awk -v latency="$latency" -v loss="$loss" -v threshold="$LATENCY_THRESHOLD_MS" '
        BEGIN {
            if (latency == "NaN" || loss == "NaN" || latency > threshold || loss > 0) {
                exit 0
            }
            exit 1
        }
    '
}

measure_and_push() {
    local profile="$1"
    local embb_allocated="$2"
    local urllc_allocated="$3"
    local output latency loss violation

    set +e
    output=$(bash scripts/measure-urllc-sla.sh)
    local rc=$?
    set -e
    printf '%s\n' "$output"

    latency=$(printf '%s\n' "$output" | extract_metric URLLC_LATENCY_AVG_MS)
    loss=$(printf '%s\n' "$output" | extract_metric URLLC_PACKET_LOSS_PERCENT)
    latency="${latency:-NaN}"
    loss="${loss:-100}"

    violation="0"
    if [ "$rc" -ne 0 ] || is_sla_violation "$latency" "$loss"; then
        violation="1"
    fi

    bash scripts/push-slice-metrics.sh \
        --profile "$profile" \
        --urllc-latency-ms "$latency" \
        --urllc-jitter-ms 0 \
        --urllc-loss-percent "$loss" \
        --embb-allocated-mbps "$embb_allocated" \
        --urllc-allocated-mbps "$urllc_allocated" \
        --sla-violation "$violation"
}

echo "Starting monitoring stack if local images are available"
if ! docker compose --profile monitoring up -d --pull never prometheus pushgateway grafana; then
    echo "WARN: monitoring stack was not started. Start it manually if Pushgateway/Grafana are not already running."
fi

echo "Starting URLLC traffic target"
docker compose --profile traffic up -d urllc-iperf-server

mkdir -p reports
cat > reports/controller-state.json <<'EOF'
{
  "healthy_cycles": 0,
  "profile": "dynamic-normal"
}
EOF

echo
echo "Step 1: apply dynamic-normal and measure healthy baseline"
bash scripts/apply-slice-policy.sh --profile dynamic-normal
measure_and_push dynamic-normal 12 3

echo
echo "Step 2: apply fault-urllc-congestion and measure SLA violation"
bash scripts/apply-slice-policy.sh --profile fault-urllc-congestion
measure_and_push fault-urllc-congestion 12 1

echo
echo "Step 3: run controller once; expected policy is dynamic-urllc-priority when SLA is violated"
python3 scripts/controller/sla-controller.py --once \
    --latency-threshold-ms "$LATENCY_THRESHOLD_MS" \
    --loss-threshold-percent 0

echo
echo "Current tc classes:"
docker exec upf-embb tc class show dev ogstun
docker exec upf-urllc tc class show dev ogstun

echo
echo "Verification commands:"
cat <<'EOF'
bash scripts/apply-slice-policy.sh --profile fault-urllc-congestion
bash scripts/measure-urllc-sla.sh
python3 scripts/controller/sla-controller.py --once
docker exec upf-embb tc class show dev ogstun
docker exec upf-urllc tc class show dev ogstun
EOF

echo
echo "Grafana: http://localhost:3000/d/5g-network-slicing/5g-network-slicing-resource-optimization"
echo "Prometheus: http://localhost:9090"
echo "Pushgateway: http://localhost:9091"
