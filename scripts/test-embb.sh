#!/bin/bash
set -euo pipefail

IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
SERVER="${EMBB_SERVER_IP:-172.20.0.221}"
PORT="${EMBB_PORT:-5201}"
DURATION="${DURATION:-30}"
PARALLEL="${PARALLEL:-4}"
REPORT_DIR="${REPORT_DIR:-reports}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$REPORT_DIR/embb-test-$TIMESTAMP.log}"
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

    route=$(docker exec ue-embb ip route get "$target" 2>/dev/null || true)
    echo "Route to $target:"
    echo "$route"

    if echo "$route" | grep -q 'dev uesimtun0'; then
        echo "PASS: route to $target goes through uesimtun0"
        return 0
    fi

    if echo "$route" | grep -q 'dev eth0'; then
        echo "FAIL: route to $target goes through eth0, so eMBB measurement is not on the UE tunnel"
        return 1
    fi

    echo "WARN: route to $target does not clearly show uesimtun0 or eth0"
    return 1
}

mkdir -p "$REPORT_DIR"
exec > >(tee "$LOG_FILE") 2>&1

docker compose --profile traffic up -d embb-iperf-server >/dev/null
need_container ue-embb
need_container embb-iperf-server

UE_IP=$(docker exec ue-embb ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
if [ -z "$UE_IP" ]; then
    echo "ue-embb has no uesimtun0 address" >&2
    exit 1
fi

docker exec ue-embb ip route replace "$SERVER/32" dev uesimtun0 src "$UE_IP" 2>/dev/null || true

echo "eMBB downlink TCP throughput test"
echo "Log: $LOG_FILE"
echo "uesimtun0 IP: $UE_IP"
echo "server=$SERVER:$PORT duration=${DURATION}s parallel=$PARALLEL reverse=true"
route_check "$SERVER"

IPERF_OUT=$(mktemp)
docker run --rm \
    --network container:ue-embb \
    "$IMAGE" \
    -c "$SERVER" -p "$PORT" -B "$UE_IP" -P "$PARALLEL" -t "$DURATION" -R \
    | tee "$IPERF_OUT"

echo
echo "eMBB throughput summary:"
grep -E '\[SUM\].*(sender|receiver)|receiver$' "$IPERF_OUT" || true
