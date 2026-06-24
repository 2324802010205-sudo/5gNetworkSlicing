#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUNS="${RUNS:-3}"
DURATION="${DURATION:-15}"
PARALLEL=2
STRESS=false
REPORT_DIR="${REPORT_DIR:-reports}"
CSV_FILE="$REPORT_DIR/recalibration-after-upgrade.csv"
CAPACITY_FILE="$REPORT_DIR/capacity.env"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/recalibrate-after-upgrade.sh
  bash scripts/recalibrate-after-upgrade.sh --stress

Default: RUNS=3, DURATION=15, PARALLEL=2.
--stress is the only mode that uses PARALLEL=4.
EOF
}

parse_sum_receiver_mbps() {
    local file="$1"

    awk '
        /\[SUM\].*receiver/ {line=$0}
        END {
            if (line == "") exit 1
            count=split(line, fields, /[[:space:]]+/)
            for (i=1; i<=count; i++) {
                if (fields[i] ~ /bits\/sec$/) {
                    value=fields[i-1]
                    unit=fields[i]
                    break
                }
            }
            if (value == "" || unit == "") exit 1
            if (unit == "bits/sec") factor=0.000001
            else if (unit == "Kbits/sec") factor=0.001
            else if (unit == "Mbits/sec") factor=1
            else if (unit == "Gbits/sec") factor=1000
            else exit 1
            printf "%.3f\n", value * factor
        }
    ' "$file"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --stress)
            STRESS=true
            PARALLEL=4
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || ! [[ "$DURATION" =~ ^[1-9][0-9]*$ ]]; then
    echo "RUNS and DURATION must be positive integers" >&2
    exit 2
fi

mkdir -p "$REPORT_DIR"

echo "Step 1: VM resource check"
bash scripts/check-vm-resources.sh

echo
echo "Step 2: apply no-policy"
bash scripts/apply-slice-policy.sh --profile no-policy

echo
echo "Step 3: clear root qdisc on both UPFs"
docker exec upf-embb sh -c 'tc qdisc del dev ogstun root 2>/dev/null || true'
docker exec upf-urllc sh -c 'tc qdisc del dev ogstun root 2>/dev/null || true'

echo
echo "Step 4: start eMBB iperf server"
docker compose --profile traffic up -d embb-iperf-server

printf 'timestamp,run,duration,parallel,receiver_mbps,status,log_file\n' > "$CSV_FILE"
VALID_VALUES=()

echo
echo "Step 5: run $RUNS eMBB measurements (duration=${DURATION}s parallel=$PARALLEL stress=$STRESS)"
for run in $(seq 1 "$RUNS"); do
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log_file="$REPORT_DIR/recalibration-run-${run}-$(date +%Y%m%d-%H%M%S).log"

    set +e
    output=$(DURATION="$DURATION" PARALLEL="$PARALLEL" LOG_FILE="$log_file" \
        bash scripts/measure-embb-throughput.sh)
    rc=$?
    set -e
    printf '%s\n' "$output"

    receiver_mbps=$(parse_sum_receiver_mbps "$log_file" 2>/dev/null || true)
    status=$(printf '%s\n' "$output" | awk -F= '$1 == "STATUS" {value=$2} END {print value}')
    receiver_mbps="${receiver_mbps:-NaN}"
    status="${status:-FAIL}"

    if [ "$rc" -eq 0 ] && [ "$status" = "PASS" ] &&
        awk -v value="$receiver_mbps" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}'; then
        VALID_VALUES+=("$receiver_mbps")
    else
        status="FAIL"
        receiver_mbps="NaN"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$timestamp" "$run" "$DURATION" "$PARALLEL" "$receiver_mbps" "$status" "$log_file" \
        >> "$CSV_FILE"
done

if [ "${#VALID_VALUES[@]}" -eq 0 ]; then
    echo "No valid receiver measurements; capacity.env was not updated." >&2
    exit 1
fi

stats=$(printf '%s\n' "${VALID_VALUES[@]}" | awk '
    NR == 1 {min=$1; max=$1}
    {sum += $1; if ($1 < min) min=$1; if ($1 > max) max=$1}
    END {printf "%.3f %.3f %.3f", min, sum / NR, max}
')
read -r min_mbps avg_mbps max_mbps <<< "$stats"
safe_total=$(awk -v avg="$avg_mbps" 'BEGIN {printf "%.3f", 0.7 * avg}')

if awk -v safe="$safe_total" 'BEGIN {exit !(safe < 15)}'; then
    normal_embb=12
    normal_urllc=3
    priority_embb=10
    priority_urllc=5
else
    normal_embb=$(awk -v safe="$safe_total" 'BEGIN {printf "%.0f", 0.8 * safe}')
    normal_urllc=$(awk -v safe="$safe_total" 'BEGIN {value=int(0.2 * safe + 0.5); if (value < 3) value=3; print value}')
    priority_embb=$(awk -v safe="$safe_total" 'BEGIN {printf "%.0f", 0.65 * safe}')
    priority_urllc=$(awk -v safe="$safe_total" 'BEGIN {value=int(0.35 * safe + 0.5); if (value < 5) value=5; print value}')
fi

cat > "$CAPACITY_FILE" <<EOF
EMBB_CEILING_MBPS=$avg_mbps
SAFE_TOTAL_MBPS=$safe_total
DYNAMIC_NORMAL_EMBB_MBPS=$normal_embb
DYNAMIC_NORMAL_URLLC_MBPS=$normal_urllc
DYNAMIC_PRIORITY_EMBB_MBPS=$priority_embb
DYNAMIC_PRIORITY_URLLC_MBPS=$priority_urllc
EOF

echo
echo "Recalibration complete"
echo "receiver_mbps min=$min_mbps avg=$avg_mbps max=$max_mbps"
echo "safe_total_mbps=$safe_total"
echo "CSV: $CSV_FILE"
echo "Capacity: $CAPACITY_FILE"
