#!/bin/bash
set -euo pipefail

IPERF_IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
IPERF_SERVER="${IPERF_SERVER:-embb-iperf-server}"
IPERF_SERVER_IP="${IPERF_SERVER_IP:-172.20.0.221}"
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-20}"
FLOWS="${FLOWS:-1 2 4 8}"
CLIENT_PREFIX="embb-iperf-debug-$$"

cleanup() {
    docker rm -f "${CLIENT_PREFIX}-bridge" "${CLIENT_PREFIX}-ue" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running." >&2
        exit 1
    fi
}

ensure_iperf_server() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$IPERF_SERVER" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Starting $IPERF_SERVER..."
        docker compose up -d "$IPERF_SERVER" >/dev/null
    fi
}

ue_ip() {
    docker exec ue-embb ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

ogstun_tx_bytes() {
    docker exec upf-embb awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev
}

iperf_mbps() {
    awk '
      /receiver/ && /bits\/sec/ {
        value = $(NF - 2)
        unit = $(NF - 1)
        if (unit == "Kbits/sec") value = value / 1000
        if (unit == "Gbits/sec") value = value * 1000
        last = value
      }
      END {
        if (last == "") print "n/a";
        else printf "%.2f", last
      }'
}

run_bridge_baseline() {
    local network="$1"
    local flows="$2"
    docker rm -f "${CLIENT_PREFIX}-bridge" >/dev/null 2>&1 || true
    docker run --rm \
        --name "${CLIENT_PREFIX}-bridge" \
        --network "$network" \
        "$IPERF_IMAGE" \
        -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" -t "$DURATION" -P "$flows" 2>&1
}

run_tunnel_test() {
    local flows="$1"
    local mode="$2"
    local before after output mbps tunnel_mbps
    local reverse_arg=()

    if [ "$mode" = "download" ]; then
        reverse_arg=(-R)
    fi

    before=$(ogstun_tx_bytes)
    docker rm -f "${CLIENT_PREFIX}-ue" >/dev/null 2>&1 || true
    output=$(docker run --rm \
        --name "${CLIENT_PREFIX}-ue" \
        --network container:ue-embb \
        "$IPERF_IMAGE" \
        -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" \
        "${reverse_arg[@]}" \
        -B "$EMBB_IP" -t "$DURATION" -P "$flows" 2>&1 || true)
    after=$(ogstun_tx_bytes)

    mbps=$(printf "%s\n" "$output" | iperf_mbps)
    tunnel_mbps=$(awk -v before="$before" -v after="$after" -v seconds="$DURATION" \
        'BEGIN {printf "%.2f", (after - before) * 8 / seconds / 1000000}')

    printf "%-12s %-6s %-14s %-14s\n" "$mode" "$flows" "$mbps" "$tunnel_mbps"
}

echo "============================================================"
echo "  eMBB throughput debug"
echo "============================================================"
echo

ensure_iperf_server
for c in upf-embb ue-embb "$IPERF_SERVER"; do
    need_container "$c"
done

EMBB_IP=$(ue_ip)
CORE_NETWORK=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$IPERF_SERVER")
if [ -z "$EMBB_IP" ]; then
    echo "ue-embb has no uesimtun0 IP. Run: bash ./fix-upf.sh" >&2
    exit 1
fi
if [ -z "$CORE_NETWORK" ]; then
    echo "Could not detect Docker network for $IPERF_SERVER." >&2
    exit 1
fi

echo "Server     : $IPERF_SERVER_IP:$IPERF_PORT"
echo "UE eMBB IP : $EMBB_IP"
echo "Core net   : $CORE_NETWORK"
echo "Duration   : ${DURATION}s"
echo
echo "Route from ue-embb to server through uesimtun0:"
docker exec ue-embb ip route get "$IPERF_SERVER_IP" oif uesimtun0 from "$EMBB_IP" 2>/dev/null || true
echo

echo "[1] Docker bridge baseline, not forced through 5G tunnel"
for flows in $FLOWS; do
    result=$(run_bridge_baseline "$CORE_NETWORK" "$flows" | iperf_mbps)
    printf "bridge       %-6s %-14s %-14s\n" "$flows" "$result" "n/a"
done

echo
echo "[2] 5G tunnel tests"
printf "%-12s %-6s %-14s %-14s\n" "mode" "flows" "iperf_mbps" "ogstun_mbps"
for flows in $FLOWS; do
    run_tunnel_test "$flows" "upload"
    run_tunnel_test "$flows" "download"
done

echo
echo "Interpretation:"
echo "- bridge high, tunnel low: bottleneck is UPF/GTP/VM CPU, not iperf3."
echo "- upload high, download low: reverse/downlink path or UPF TX queue is the bottleneck."
echo "- throughput drops as flows increase: parallel TCP is overloading the userspace GTP path."
echo "- reverse download drops with many flows: TCP ACK/uplink feedback can double the GTP scheduling pressure."
echo "- iperf_mbps and ogstun_mbps should be close; if not, the traffic is not fully on the tunnel path."
