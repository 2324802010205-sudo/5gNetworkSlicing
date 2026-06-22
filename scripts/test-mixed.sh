#!/bin/bash
set -euo pipefail

IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
EMBB_SERVER="${EMBB_SERVER_IP:-172.20.0.221}"
EMBB_PORT="${EMBB_PORT:-5201}"
URLLC_SERVER="${URLLC_SERVER_IP:-172.20.0.222}"
URLLC_PORT="${URLLC_PORT:-5202}"
DURATION="${DURATION:-45}"
EMBB_PARALLEL="${EMBB_PARALLEL:-6}"
URLLC_BITRATE="${URLLC_BITRATE:-1M}"
URLLC_PACKET_SIZE="${URLLC_PACKET_SIZE:-120}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
EMBB_CLIENT="mixed-embb-load-$RUN_ID"

cleanup() {
    docker rm -f "$EMBB_CLIENT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running" >&2
        exit 1
    fi
}

docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server >/dev/null
for c in ue-embb ue-urllc embb-iperf-server urllc-iperf-server; do
    need_container "$c"
done

EMBB_IP=$(docker exec ue-embb ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
URLLC_IP=$(docker exec ue-urllc ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
if [ -z "$EMBB_IP" ] || [ -z "$URLLC_IP" ]; then
    echo "One UE tunnel is missing" >&2
    exit 1
fi

docker exec ue-embb ip route replace "$EMBB_SERVER/32" dev uesimtun0 src "$EMBB_IP" 2>/dev/null || true
docker exec ue-urllc ip route replace "$URLLC_SERVER/32" dev uesimtun0 src "$URLLC_IP" 2>/dev/null || true

echo "Mixed test: saturate eMBB while measuring URLLC UDP"
echo "eMBB UE=$EMBB_IP server=$EMBB_SERVER:$EMBB_PORT parallel=$EMBB_PARALLEL"
echo "URLLC UE=$URLLC_IP server=$URLLC_SERVER:$URLLC_PORT bitrate=$URLLC_BITRATE packet=${URLLC_PACKET_SIZE}B"

docker run -d --rm \
    --name "$EMBB_CLIENT" \
    --network container:ue-embb \
    "$IMAGE" \
    -c "$EMBB_SERVER" -p "$EMBB_PORT" -B "$EMBB_IP" -P "$EMBB_PARALLEL" -t "$DURATION" \
    >/dev/null

sleep 3
docker run --rm \
    --network container:ue-urllc \
    "$IMAGE" \
    -c "$URLLC_SERVER" -p "$URLLC_PORT" -B "$URLLC_IP" -u -b "$URLLC_BITRATE" -l "$URLLC_PACKET_SIZE" -t "$((DURATION - 5))"
