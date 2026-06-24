#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DURATION="${DURATION:-30}"
PARALLEL=2
REPORT_DIR="${REPORT_DIR:-reports}"
CSV_FILE="${CSV_FILE:-$REPORT_DIR/mongo-fix-comparison.csv}"
BASELINE_VALUES="${BASELINE_VALUES:-28.3 29.4 28.8}"

read -r -a BEFORE <<< "$BASELINE_VALUES"
if [ "${#BEFORE[@]}" -ne 3 ]; then
    echo "BASELINE_VALUES must contain exactly three Mbps values." >&2
    exit 2
fi

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

summary_value() {
    local operation="$1"
    shift
    printf '%s\n' "$@" | awk -v operation="$operation" '
        NR == 1 {min=$1; max=$1}
        {sum += $1; if ($1 < min) min=$1; if ($1 > max) max=$1}
        END {
            if (operation == "min") printf "%.3f", min
            else if (operation == "max") printf "%.3f", max
            else printf "%.3f", sum / NR
        }
    '
}

comparison_fields() {
    local before="$1"
    local after="$2"
    awk -v before="$before" -v after="$after" 'BEGIN {
        delta=after-before
        percent=(before > 0 ? delta / before * 100 : 0)
        printf "%.3f,%.3f", delta, percent
    }'
}

mkdir -p "$REPORT_DIR"

echo "Applying no-policy and starting the eMBB iperf server"
bash scripts/apply-slice-policy.sh --profile no-policy
docker compose --profile traffic up -d embb-iperf-server

printf 'run,before_mbps,after_mbps,delta_mbps,delta_percent,status,log_file\n' > "$CSV_FILE"
AFTER=()

for index in 0 1 2; do
    run=$((index + 1))
    log_file="$REPORT_DIR/mongo-fix-after-run-${run}-$(date +%Y%m%d-%H%M%S).log"

    echo
    echo "Run $run/3: DURATION=$DURATION PARALLEL=$PARALLEL"
    set +e
    DURATION="$DURATION" PARALLEL="$PARALLEL" LOG_FILE="$log_file" \
        bash scripts/test-embb.sh
    rc=$?
    set -e

    after=$(parse_sum_receiver_mbps "$log_file" 2>/dev/null || true)
    if [ "$rc" -eq 0 ] && [ -n "$after" ]; then
        status="PASS"
        AFTER+=("$after")
        comparison=$(comparison_fields "${BEFORE[$index]}" "$after")
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$run" "${BEFORE[$index]}" "$after" "$comparison" "$status" "$log_file" >> "$CSV_FILE"
    else
        status="FAIL"
        printf '%s,%s,NaN,NaN,NaN,%s,%s\n' \
            "$run" "${BEFORE[$index]}" "$status" "$log_file" >> "$CSV_FILE"
    fi
done

if [ "${#AFTER[@]}" -eq 3 ]; then
    for operation in min avg max; do
        before_summary=$(summary_value "$operation" "${BEFORE[@]}")
        after_summary=$(summary_value "$operation" "${AFTER[@]}")
        comparison=$(comparison_fields "$before_summary" "$after_summary")
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$operation" "$before_summary" "$after_summary" "$comparison" "PASS" "" >> "$CSV_FILE"
    done
else
    echo "WARNING: One or more after-fix tests failed; summary rows were not generated." >&2
fi

echo
echo "Comparison CSV: $CSV_FILE"
if command -v column >/dev/null 2>&1; then
    column -s, -t "$CSV_FILE"
else
    cat "$CSV_FILE"
fi
