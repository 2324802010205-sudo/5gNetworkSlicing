#!/bin/bash
set -euo pipefail

DURATION="${DURATION:-10}"
PARALLEL="${PARALLEL:-2}"
REPORT_DIR="${REPORT_DIR:-reports}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$REPORT_DIR/embb-throughput-$TIMESTAMP.log}"
TEST_LOG_FILE="${TEST_LOG_FILE:-$REPORT_DIR/embb-test-$TIMESTAMP.log}"

parse_sum_receiver_mbps() {
    local file="$1"

    awk '
        /\[SUM\].*receiver/ { line = $0 }
        END {
            if (line == "") {
                exit 1
            }
            n = split(line, fields, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                if (fields[i] ~ /bits\/sec$/) {
                    value = fields[i - 1]
                    unit = fields[i]
                    break
                }
            }
            if (value == "" || unit == "") {
                exit 1
            }
            factor = 1
            if (unit == "bits/sec") {
                factor = 0.000001
            } else if (unit == "Kbits/sec") {
                factor = 0.001
            } else if (unit == "Mbits/sec") {
                factor = 1
            } else if (unit == "Gbits/sec") {
                factor = 1000
            } else {
                exit 1
            }
            printf "%.3f\n", value * factor
        }
    ' "$file"
}

fail_output() {
    echo "LOG_FILE=$LOG_FILE"
    echo "EMBB_THROUGHPUT_MBPS=NaN"
    echo "STATUS=FAIL"
    exit 1
}

mkdir -p "$REPORT_DIR"

set +e
DURATION="$DURATION" PARALLEL="$PARALLEL" LOG_FILE="$TEST_LOG_FILE" \
    bash scripts/test-embb.sh > "$LOG_FILE" 2>&1
TEST_RC=$?
set -e

if [ "$TEST_RC" -ne 0 ]; then
    fail_output
fi

if grep -Eiq 'Broken pipe|Connection timed out|timed out|iperf3: error|Connection refused|No route to host' "$LOG_FILE"; then
    fail_output
fi

ZERO_BYTE_LINES=$(grep -Ec '0\.00 Bytes' "$LOG_FILE" || true)
if [ "$ZERO_BYTE_LINES" -ge 3 ]; then
    fail_output
fi

if grep -Eq '\[SUM\].*0\.00 Bytes.*receiver' "$LOG_FILE"; then
    fail_output
fi

MBPS=$(parse_sum_receiver_mbps "$LOG_FILE" 2>/dev/null || true)
if [ -z "$MBPS" ]; then
    fail_output
fi

if ! awk -v mbps="$MBPS" 'BEGIN { exit !(mbps > 0) }'; then
    fail_output
fi

echo "LOG_FILE=$LOG_FILE"
echo "EMBB_THROUGHPUT_MBPS=$MBPS"
echo "STATUS=PASS"
