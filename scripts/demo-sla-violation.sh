#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LATENCY_THRESHOLD_MS="${LATENCY_THRESHOLD_MS:-15}"
RESULTS_CSV="${RESULTS_CSV:-reports/closed-loop-results.csv}"

LAST_EMBB_MBPS="NaN"
LAST_EMBB_STATUS="FAIL"
LAST_URLLC_LATENCY="NaN"
LAST_URLLC_LOSS="100"
LAST_URLLC_STATUS="FAIL"
LAST_SLA_VIOLATION="1"

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

measure_embb() {
    local output rc

    set +e
    output=$(DURATION=10 PARALLEL=2 bash scripts/measure-embb-throughput.sh)
    rc=$?
    set -e
    printf '%s\n' "$output"

    LAST_EMBB_MBPS=$(printf '%s\n' "$output" | extract_metric EMBB_THROUGHPUT_MBPS)
    LAST_EMBB_STATUS=$(printf '%s\n' "$output" | extract_metric STATUS)
    LAST_EMBB_MBPS="${LAST_EMBB_MBPS:-NaN}"
    LAST_EMBB_STATUS="${LAST_EMBB_STATUS:-FAIL}"

    if [ "$rc" -ne 0 ]; then
        LAST_EMBB_STATUS="FAIL"
    fi
}

measure_urllc() {
    local output rc

    set +e
    output=$(bash scripts/measure-urllc-sla.sh)
    rc=$?
    set -e
    printf '%s\n' "$output"

    LAST_URLLC_LATENCY=$(printf '%s\n' "$output" | extract_metric URLLC_LATENCY_AVG_MS)
    LAST_URLLC_LOSS=$(printf '%s\n' "$output" | extract_metric URLLC_PACKET_LOSS_PERCENT)
    LAST_URLLC_STATUS=$(printf '%s\n' "$output" | extract_metric STATUS)
    LAST_URLLC_LATENCY="${LAST_URLLC_LATENCY:-NaN}"
    LAST_URLLC_LOSS="${LAST_URLLC_LOSS:-100}"
    LAST_URLLC_STATUS="${LAST_URLLC_STATUS:-FAIL}"

    LAST_SLA_VIOLATION="0"
    if [ "$rc" -ne 0 ] || is_sla_violation "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS"; then
        LAST_SLA_VIOLATION="1"
    fi
}

push_snapshot() {
    local profile="$1"
    local embb_allocated="$2"
    local urllc_allocated="$3"
    local embb_mbps="$4"
    local latency="$5"
    local loss="$6"
    local violation="$7"
    local args

    args=(
        bash scripts/push-slice-metrics.sh
        --profile "$profile"
        --urllc-latency-ms "$latency"
        --urllc-jitter-ms 0
        --urllc-loss-percent "$loss"
        --embb-allocated-mbps "$embb_allocated"
        --urllc-allocated-mbps "$urllc_allocated"
        --sla-violation "$violation"
    )

    if [ -n "$embb_mbps" ] && [ "$embb_mbps" != "NaN" ]; then
        args+=(--embb-mbps "$embb_mbps")
    fi

    "${args[@]}"
}

append_result() {
    local step="$1"
    local profile="$2"
    local embb_allocated="$3"
    local urllc_allocated="$4"
    local status="$5"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$step" \
        "$profile" \
        "$LAST_EMBB_MBPS" \
        "$LAST_URLLC_LATENCY" \
        "$LAST_URLLC_LOSS" \
        "$LAST_SLA_VIOLATION" \
        "$embb_allocated" \
        "$urllc_allocated" \
        "$status" >> "$RESULTS_CSV"
}

profile_allocations() {
    local profile="$1"
    case "$profile" in
        dynamic-urllc-priority) echo "10 5" ;;
        no-policy) echo "0 0" ;;
        fault-urllc-congestion) echo "12 1" ;;
        *) echo "12 3" ;;
    esac
}

echo "Starting monitoring stack if local images are available"
if ! docker compose --profile monitoring up -d --pull never prometheus pushgateway grafana; then
    echo "WARN: monitoring stack was not started. Start it manually if Pushgateway/Grafana are not already running."
fi

echo "Starting traffic targets"
docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server

mkdir -p reports
cat > reports/controller-state.json <<'EOF'
{
  "healthy_cycles": 0,
  "profile": "dynamic-normal"
}
EOF

cat > "$RESULTS_CSV" <<'EOF'
timestamp,step,profile,embb_throughput_mbps,urllc_latency_ms,urllc_loss_percent,sla_violation,embb_allocated_mbps,urllc_allocated_mbps,status
EOF

echo
echo "Step 1: no-policy eMBB throughput baseline"
bash scripts/apply-slice-policy.sh --profile no-policy
LAST_URLLC_LATENCY="NaN"
LAST_URLLC_LOSS="0"
LAST_SLA_VIOLATION="0"
measure_embb
push_snapshot no-policy 0 0 "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result no-policy-baseline no-policy 0 0 "$LAST_EMBB_STATUS"

echo
echo "Step 2: dynamic-normal eMBB throughput and URLLC SLA"
bash scripts/apply-slice-policy.sh --profile dynamic-normal
measure_embb
measure_urllc
push_snapshot dynamic-normal 12 3 "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result dynamic-normal dynamic-normal 12 3 "$LAST_EMBB_STATUS/$LAST_URLLC_STATUS"

echo
echo "Step 3: inject URLLC congestion fault"
bash scripts/apply-slice-policy.sh --profile fault-urllc-congestion
LAST_EMBB_MBPS="NaN"
measure_urllc
push_snapshot fault-urllc-congestion 12 1 "" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result fault-urllc-congestion fault-urllc-congestion 12 1 "$LAST_URLLC_STATUS"

echo
echo "Step 4: run controller once; expected policy is dynamic-urllc-priority"
python3 scripts/controller/sla-controller.py --once \
    --latency-threshold-ms "$LATENCY_THRESHOLD_MS" \
    --loss-threshold-percent 0

echo
echo "Step 5: measure eMBB throughput and recovered URLLC SLA under dynamic-urllc-priority"
measure_embb
measure_urllc
push_snapshot dynamic-urllc-priority 10 5 "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result dynamic-urllc-priority dynamic-urllc-priority 10 5 "$LAST_EMBB_STATUS/$LAST_URLLC_STATUS"

echo
echo "Step 6: let controller run 3 more iterations so hysteresis can return to dynamic-normal"
python3 scripts/controller/sla-controller.py --interval 10 --iterations 3 \
    --latency-threshold-ms "$LATENCY_THRESHOLD_MS" \
    --loss-threshold-percent 0

CURRENT_PROFILE=$(python3 -c 'import json; print(json.load(open("reports/controller-state.json")).get("profile", "dynamic-normal"))' 2>/dev/null || echo "dynamic-normal")
read -r FINAL_EMBB_ALLOC FINAL_URLLC_ALLOC <<< "$(profile_allocations "$CURRENT_PROFILE")"

echo
echo "Step 7: final eMBB throughput and URLLC SLA snapshot for $CURRENT_PROFILE"
measure_embb
measure_urllc
push_snapshot "$CURRENT_PROFILE" "$FINAL_EMBB_ALLOC" "$FINAL_URLLC_ALLOC" "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result final-snapshot "$CURRENT_PROFILE" "$FINAL_EMBB_ALLOC" "$FINAL_URLLC_ALLOC" "$LAST_EMBB_STATUS/$LAST_URLLC_STATUS"

echo
echo "Current tc classes:"
docker exec upf-embb tc class show dev ogstun
docker exec upf-urllc tc class show dev ogstun

echo
echo "Results CSV: $RESULTS_CSV"

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
