#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LATENCY_THRESHOLD_MS="${LATENCY_THRESHOLD_MS:-15}"
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://localhost:9091}"
RESULTS_CSV="${RESULTS_CSV:-reports/closed-loop-results.csv}"
SUMMARY_MD="${SUMMARY_MD:-reports/closed-loop-summary.md}"
CAPACITY_FILE="reports/capacity.env"
CAPACITY_SOURCE="fallback defaults"
DYNAMIC_NORMAL_EMBB_MBPS=12
DYNAMIC_NORMAL_URLLC_MBPS=3
DYNAMIC_PRIORITY_EMBB_MBPS=10
DYNAMIC_PRIORITY_URLLC_MBPS=5

LAST_EMBB_MBPS="NaN"
LAST_EMBB_STATUS="FAIL"
LAST_URLLC_LATENCY="NaN"
LAST_URLLC_LOSS="100"
LAST_URLLC_STATUS="FAIL"
LAST_SLA_VIOLATION="1"

NO_POLICY_EMBB="NaN"
DYNAMIC_NORMAL_EMBB="NaN"
URLLC_BASELINE_LATENCY="NaN"
FAULT_URLLC_LATENCY="NaN"
CONTROLLER_SELECTED_POLICY="unknown"
LAST_CONTROLLER_POLICY="unknown"
PRIORITY_EMBB="NaN"
RECOVERY_URLLC_LATENCY="NaN"
FINAL_POLICY="unknown"

is_positive_number() {
    awk -v value="$1" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}'
}

load_capacity() {
    if [ ! -f "$CAPACITY_FILE" ]; then
        return
    fi

    unset DYNAMIC_NORMAL_EMBB_MBPS DYNAMIC_NORMAL_URLLC_MBPS
    unset DYNAMIC_PRIORITY_EMBB_MBPS DYNAMIC_PRIORITY_URLLC_MBPS
    # shellcheck disable=SC1090
    source "$CAPACITY_FILE"
    if is_positive_number "${DYNAMIC_NORMAL_EMBB_MBPS:-}" &&
        is_positive_number "${DYNAMIC_NORMAL_URLLC_MBPS:-}" &&
        is_positive_number "${DYNAMIC_PRIORITY_EMBB_MBPS:-}" &&
        is_positive_number "${DYNAMIC_PRIORITY_URLLC_MBPS:-}"; then
        CAPACITY_SOURCE="$CAPACITY_FILE"
    else
        echo "WARNING: Invalid $CAPACITY_FILE; using fallback defaults." >&2
        DYNAMIC_NORMAL_EMBB_MBPS=12
        DYNAMIC_NORMAL_URLLC_MBPS=3
        DYNAMIC_PRIORITY_EMBB_MBPS=10
        DYNAMIC_PRIORITY_URLLC_MBPS=5
    fi
}

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

reset_pushgateway_metrics() {
    echo "Resetting old Pushgateway slice-controller metrics"
    curl -fsS -X DELETE "$PUSHGATEWAY_URL/metrics/job/slice-controller" >/dev/null 2>&1 || true
    {
        cat <<'EOF'
# HELP slice_policy_active Active policy profile flag.
# TYPE slice_policy_active gauge
slice_policy_active{profile="no-policy"} 0
slice_policy_active{profile="static"} 0
slice_policy_active{profile="dynamic-normal"} 0
slice_policy_active{profile="dynamic-urllc-priority"} 0
slice_policy_active{profile="fault-urllc-congestion"} 0
EOF
    } | curl -fsS -X PUT --data-binary @- "$PUSHGATEWAY_URL/metrics/job/slice-controller" >/dev/null 2>&1 || true
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
    local phase="$1"
    local profile="$2"
    local embb_allocated="$3"
    local urllc_allocated="$4"
    local status="$5"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$phase" \
        "$profile" \
        "$embb_allocated" \
        "$urllc_allocated" \
        "$LAST_EMBB_MBPS" \
        "$LAST_URLLC_LATENCY" \
        "$LAST_URLLC_LOSS" \
        "$LAST_SLA_VIOLATION" \
        "$status" >> "$RESULTS_CSV"
}

run_controller() {
    local iterations="$1"
    local output rc

    set +e
    if [ "$iterations" = "1" ]; then
        output=$(python3 scripts/controller/sla-controller.py --once \
            --latency-threshold-ms "$LATENCY_THRESHOLD_MS" \
            --loss-threshold-percent 0 2>&1)
        rc=$?
    else
        output=$(python3 scripts/controller/sla-controller.py --interval 10 --iterations "$iterations" \
            --latency-threshold-ms "$LATENCY_THRESHOLD_MS" \
            --loss-threshold-percent 0 2>&1)
        rc=$?
    fi
    set -e
    printf '%s\n' "$output"

    LAST_CONTROLLER_POLICY=$(printf '%s\n' "$output" | extract_metric CONTROLLER_POLICY)
    LAST_CONTROLLER_POLICY="${LAST_CONTROLLER_POLICY:-unknown}"
    if [ "$CONTROLLER_SELECTED_POLICY" = "unknown" ] && [ "$LAST_CONTROLLER_POLICY" != "unknown" ]; then
        CONTROLLER_SELECTED_POLICY="$LAST_CONTROLLER_POLICY"
    fi

    if [ "$rc" -ne 0 ]; then
        echo "Controller failed" >&2
        exit "$rc"
    fi
}

profile_allocations() {
    local profile="$1"
    case "$profile" in
        dynamic-urllc-priority) echo "$DYNAMIC_PRIORITY_EMBB_MBPS $DYNAMIC_PRIORITY_URLLC_MBPS" ;;
        no-policy) echo "0 0" ;;
        fault-urllc-congestion) echo "$DYNAMIC_NORMAL_EMBB_MBPS 1" ;;
        *) echo "$DYNAMIC_NORMAL_EMBB_MBPS $DYNAMIC_NORMAL_URLLC_MBPS" ;;
    esac
}

write_summary() {
    cat > "$SUMMARY_MD" <<EOF
# Closed-loop Resource Allocation Demo Summary

## Key Results

- no-policy eMBB throughput: ${NO_POLICY_EMBB} Mbps
- dynamic-normal eMBB throughput: ${DYNAMIC_NORMAL_EMBB} Mbps
- URLLC baseline latency: ${URLLC_BASELINE_LATENCY} ms
- fault URLLC latency: ${FAULT_URLLC_LATENCY} ms
- controller selected policy: ${CONTROLLER_SELECTED_POLICY}
- dynamic-urllc-priority eMBB throughput: ${PRIORITY_EMBB} Mbps
- recovery URLLC latency: ${RECOVERY_URLLC_LATENCY} ms
- final policy: ${FINAL_POLICY}

## Closed-loop Evidence

The demo follows the closed-loop sequence:

1. measure URLLC SLA and eMBB throughput
2. decide whether SLA is violated
3. apply the selected slice resource policy
4. verify the result through metrics and Grafana

This demonstrates closed-loop resource allocation for the testbed. It does not implement two-path path computation.

## Testbed Scope

tc/htb/netem/fq_codel is only a testbed proxy for resource pressure and policy enforcement, not standard 5G QoS.

VM testbed uses limited RAM. Measured throughput is testbed-specific and should be recalibrated after changing vCPU/RAM.

Detailed samples are in \`${RESULTS_CSV}\`.
EOF
}

load_capacity

VM_VCPU=$(nproc)
VM_RAM=$(free -h | awk '/^Mem:/ {print $2}')
VM_SWAP=$(free -h | awk '/^Swap:/ {print $2}')
echo "VM resources:"
echo "vCPU=$VM_VCPU"
echo "RAM=$VM_RAM"
echo "Swap=$VM_SWAP"
echo "Capacity source=$CAPACITY_SOURCE"
echo

echo "Starting monitoring stack for the demo"
if ! docker compose --profile monitoring up -d prometheus pushgateway grafana; then
    echo "WARN: monitoring stack was not started. Start it manually if Pushgateway/Grafana are not already running."
fi

echo "Starting traffic targets"
docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server

mkdir -p reports
reset_pushgateway_metrics

cat > reports/controller-state.json <<'EOF'
{
  "healthy_cycles": 0,
  "profile": "dynamic-normal"
}
EOF

cat > "$RESULTS_CSV" <<'EOF'
timestamp,phase,profile,embb_allocated_mbps,urllc_allocated_mbps,embb_throughput_mbps,urllc_latency_avg_ms,urllc_loss_percent,sla_violation,status
EOF

echo
echo "Phase 1: no-policy eMBB throughput baseline"
bash scripts/apply-slice-policy.sh --profile no-policy
LAST_URLLC_LATENCY="NaN"
LAST_URLLC_LOSS="0"
LAST_SLA_VIOLATION="0"
measure_embb
NO_POLICY_EMBB="$LAST_EMBB_MBPS"
push_snapshot no-policy 0 0 "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result no-policy-baseline no-policy 0 0 "$LAST_EMBB_STATUS"

echo
echo "Phase 2: dynamic-normal eMBB throughput and URLLC SLA"
bash scripts/apply-slice-policy.sh --profile dynamic-normal
measure_embb
measure_urllc
DYNAMIC_NORMAL_EMBB="$LAST_EMBB_MBPS"
URLLC_BASELINE_LATENCY="$LAST_URLLC_LATENCY"
push_snapshot dynamic-normal "$DYNAMIC_NORMAL_EMBB_MBPS" "$DYNAMIC_NORMAL_URLLC_MBPS" "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result dynamic-normal dynamic-normal "$DYNAMIC_NORMAL_EMBB_MBPS" "$DYNAMIC_NORMAL_URLLC_MBPS" "$LAST_EMBB_STATUS/$LAST_URLLC_STATUS"

echo
echo "Phase 3: inject URLLC congestion fault"
bash scripts/apply-slice-policy.sh --profile fault-urllc-congestion
LAST_EMBB_MBPS="NaN"
measure_urllc
FAULT_URLLC_LATENCY="$LAST_URLLC_LATENCY"
push_snapshot fault-urllc-congestion "$DYNAMIC_NORMAL_EMBB_MBPS" 1 "" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result fault-urllc-congestion fault-urllc-congestion "$DYNAMIC_NORMAL_EMBB_MBPS" 1 "$LAST_URLLC_STATUS"

echo
echo "Phase 4: run controller once; expected policy is dynamic-urllc-priority"
run_controller 1

echo
echo "Phase 5: measure eMBB throughput and recovered URLLC SLA under dynamic-urllc-priority"
measure_embb
measure_urllc
PRIORITY_EMBB="$LAST_EMBB_MBPS"
RECOVERY_URLLC_LATENCY="$LAST_URLLC_LATENCY"
push_snapshot dynamic-urllc-priority "$DYNAMIC_PRIORITY_EMBB_MBPS" "$DYNAMIC_PRIORITY_URLLC_MBPS" "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result dynamic-urllc-priority dynamic-urllc-priority "$DYNAMIC_PRIORITY_EMBB_MBPS" "$DYNAMIC_PRIORITY_URLLC_MBPS" "$LAST_EMBB_STATUS/$LAST_URLLC_STATUS"

echo
echo "Phase 6: let controller run 3 more iterations so hysteresis can return to dynamic-normal"
run_controller 3

FINAL_POLICY=$(python3 -c 'import json; print(json.load(open("reports/controller-state.json")).get("profile", "dynamic-normal"))' 2>/dev/null || echo "dynamic-normal")
read -r FINAL_EMBB_ALLOC FINAL_URLLC_ALLOC <<< "$(profile_allocations "$FINAL_POLICY")"

echo
echo "Phase 7: final eMBB throughput and URLLC SLA snapshot for $FINAL_POLICY"
measure_embb
measure_urllc
RECOVERY_URLLC_LATENCY="$LAST_URLLC_LATENCY"
push_snapshot "$FINAL_POLICY" "$FINAL_EMBB_ALLOC" "$FINAL_URLLC_ALLOC" "$LAST_EMBB_MBPS" "$LAST_URLLC_LATENCY" "$LAST_URLLC_LOSS" "$LAST_SLA_VIOLATION"
append_result final-snapshot "$FINAL_POLICY" "$FINAL_EMBB_ALLOC" "$FINAL_URLLC_ALLOC" "$LAST_EMBB_STATUS/$LAST_URLLC_STATUS"

write_summary

echo
echo "Current tc classes:"
docker exec upf-embb tc class show dev ogstun
docker exec upf-urllc tc class show dev ogstun

echo
echo "Results CSV: $RESULTS_CSV"
echo "Summary: $SUMMARY_MD"

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
echo "Grafana demo: http://localhost:3000/d/5g-network-slicing-demo/5g-network-slicing-resource-optimization-demo"
echo "Grafana debug: http://localhost:3000/d/5g-network-slicing/5g-network-slicing-resource-optimization"
echo "Prometheus: http://localhost:9090"
echo "Pushgateway: http://localhost:9091"
