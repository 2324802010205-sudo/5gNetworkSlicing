#!/bin/bash
set -euo pipefail

SERVER="${URLLC_SERVER_IP:-172.20.0.222}"
REPORT_DIR="${REPORT_DIR:-reports}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$REPORT_DIR/urllc-sla-$TIMESTAMP.log}"

need_container() {
    local name="$1"
    local state

    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running" >&2
        exit 1
    fi
}

parse_loss_percent() {
    awk -F',' '
        /packet loss/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /packet loss/) {
                    gsub(/[[:space:]]/, "", $i)
                    sub(/%packetloss.*/, "", $i)
                    print $i
                    exit
                }
            }
        }
    '
}

mkdir -p "$REPORT_DIR"
exec > >(tee "$LOG_FILE") 2>&1

echo "URLLC SLA measurement"
echo "Log: $LOG_FILE"
echo "Target: $SERVER"
echo "Latency type: RTT from ping, not one-way latency"

docker compose --profile traffic up -d urllc-iperf-server >/dev/null

need_container ue-urllc
need_container urllc-iperf-server

UE_IP=$(docker exec ue-urllc ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
if [ -z "$UE_IP" ]; then
    echo "ue-urllc has no uesimtun0 address" >&2
    echo "URLLC_LATENCY_MIN_MS=NaN"
    echo "URLLC_LATENCY_AVG_MS=NaN"
    echo "URLLC_LATENCY_MAX_MS=NaN"
    echo "URLLC_LATENCY_MDEV_MS=NaN"
    echo "URLLC_PACKET_LOSS_PERCENT=100"
    echo "STATUS=FAIL"
    exit 1
fi

docker exec ue-urllc ip route replace "$SERVER/32" dev uesimtun0 src "$UE_IP" 2>/dev/null || true

ROUTE=$(docker exec ue-urllc ip route get "$SERVER" 2>/dev/null || true)
echo "uesimtun0 IP: $UE_IP"
echo "Route to $SERVER:"
echo "$ROUTE"

if ! echo "$ROUTE" | grep -q 'dev uesimtun0'; then
    echo "Route to $SERVER does not go through uesimtun0" >&2
    echo "URLLC_LATENCY_MIN_MS=NaN"
    echo "URLLC_LATENCY_AVG_MS=NaN"
    echo "URLLC_LATENCY_MAX_MS=NaN"
    echo "URLLC_LATENCY_MDEV_MS=NaN"
    echo "URLLC_PACKET_LOSS_PERCENT=100"
    echo "STATUS=FAIL"
    exit 1
fi

set +e
PING_OUTPUT=$(docker exec ue-urllc ping -I uesimtun0 -c 10 "$SERVER" 2>&1)
PING_STATUS=$?
set -e

printf '%s\n' "$PING_OUTPUT"

RTT_LINE=$(printf '%s\n' "$PING_OUTPUT" | awk '/^(rtt|round-trip) min\/avg\/max/ {print; exit}')
LOSS=$(printf '%s\n' "$PING_OUTPUT" | parse_loss_percent)
LOSS="${LOSS:-100}"

if [ -n "$RTT_LINE" ]; then
    RTT_VALUES=$(printf '%s\n' "$RTT_LINE" | awk -F'= ' '{print $2}' | awk '{print $1}')
    IFS='/' read -r LAT_MIN LAT_AVG LAT_MAX LAT_MDEV <<< "$RTT_VALUES"
    LAT_MDEV="${LAT_MDEV:-0}"
else
    LAT_MIN="NaN"
    LAT_AVG="NaN"
    LAT_MAX="NaN"
    LAT_MDEV="NaN"
fi

STATUS="FAIL"
if [ "$PING_STATUS" -eq 0 ] && [ "$LAT_AVG" != "NaN" ] && awk "BEGIN { exit !($LOSS <= 0) }"; then
    STATUS="PASS"
fi

echo "URLLC_LATENCY_MIN_MS=$LAT_MIN"
echo "URLLC_LATENCY_AVG_MS=$LAT_AVG"
echo "URLLC_LATENCY_MAX_MS=$LAT_MAX"
echo "URLLC_LATENCY_MDEV_MS=$LAT_MDEV"
echo "URLLC_PACKET_LOSS_PERCENT=$LOSS"
echo "STATUS=$STATUS"

[ "$STATUS" = "PASS" ]
