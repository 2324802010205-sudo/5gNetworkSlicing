#!/bin/bash
set -euo pipefail

IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
SERVER="${URLLC_SERVER_IP:-172.20.0.222}"
PORT="${URLLC_PORT:-5202}"
DURATION="${DURATION:-60}"
BITRATE="${URLLC_BITRATE:-200K}"
PACKET_SIZE="${URLLC_PACKET_SIZE:-128}"
REPORT_DIR="${REPORT_DIR:-reports}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$REPORT_DIR/urllc-test-$TIMESTAMP.log}"
IPERF_OUT=""

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running" >&2
        exit 1
    fi
}

cleanup() {
    if [ -n "$IPERF_OUT" ] && [ -f "$IPERF_OUT" ]; then
        rm -f "$IPERF_OUT"
    fi
}
trap cleanup EXIT

route_check() {
    local target="$1"
    local route

    route=$(docker exec ue-urllc ip route get "$target" 2>/dev/null || true)
    echo "Route to $target:"
    echo "$route"

    if echo "$route" | grep -q 'dev uesimtun0'; then
        echo "PASS: route to $target goes through uesimtun0"
        return 0
    fi

    if echo "$route" | grep -q 'dev eth0'; then
        echo "FAIL: route to $target goes through eth0, so URLLC measurement is not on the UE tunnel"
        return 1
    fi

    echo "WARN: route to $target does not clearly show uesimtun0 or eth0"
    return 1
}

ping_latency() {
    local target="$1"

    echo
    echo "Ping latency through uesimtun0:"
    if docker exec ue-urllc ping -I uesimtun0 "$target" -c 5 -W 2; then
        echo "PASS: ping -I uesimtun0 to $target completed"
    else
        echo "WARN: ping -I uesimtun0 to $target failed"
    fi
}

mkdir -p "$REPORT_DIR"
exec > >(tee "$LOG_FILE") 2>&1

docker compose --profile traffic up -d urllc-iperf-server >/dev/null
need_container ue-urllc
need_container urllc-iperf-server

UE_IP=$(docker exec ue-urllc ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
if [ -z "$UE_IP" ]; then
    echo "ue-urllc has no uesimtun0 address" >&2
    exit 1
fi

docker exec ue-urllc ip route replace "$SERVER/32" dev uesimtun0 src "$UE_IP" 2>/dev/null || true

echo "URLLC UDP small-packet test"
echo "Log: $LOG_FILE"
echo "uesimtun0 IP: $UE_IP"
echo "server=$SERVER:$PORT duration=${DURATION}s bitrate=$BITRATE packet=${PACKET_SIZE}B"
route_check "$SERVER"
ping_latency "$SERVER"

IPERF_OUT=$(mktemp)
docker run --rm \
    --network container:ue-urllc \
    "$IMAGE" \
    -c "$SERVER" -p "$PORT" -B "$UE_IP" -u -b "$BITRATE" -l "$PACKET_SIZE" -t "$DURATION" \
    | tee "$IPERF_OUT"

echo
echo "URLLC jitter/loss summary:"
grep -E 'ms.*\([0-9.]+%\)|Jitter|Lost/Total|receiver$' "$IPERF_OUT" || true
