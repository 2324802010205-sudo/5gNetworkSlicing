#!/bin/bash
set -euo pipefail

IPERF_IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
IPERF_SERVER="${IPERF_SERVER:-embb-iperf-server}"
IPERF_SERVER_IP="${IPERF_SERVER_IP:-172.20.0.221}"
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-20}"
WARMUP="${WARMUP:-3}"
FLOWS="${FLOWS:-1 2 4 8}"
CLIENT_PREFIX="embb-iperf-debug-$$"
UPLOAD_RESULTS=()
DOWNLOAD_RESULTS=()

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

ogstun_bytes() {
    local direction="$1"
    docker exec upf-embb awk -v direction="$direction" '
      $1 ~ /ogstun:/ {
        gsub(/:/, "", $1)
        if (direction == "rx") print $2
        if (direction == "tx") print $10
      }' /proc/net/dev
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
    local before after output mbps tunnel_mbps counter_name real_duration
    local reverse_arg=()

    if [ "$mode" = "download" ]; then
        reverse_arg=(-R)
        counter_name="tx"
    else
        counter_name="rx"
    fi
    real_duration=$((DURATION - WARMUP))
    if [ "$real_duration" -lt 5 ]; then
        real_duration="$DURATION"
    fi

    docker rm -f "${CLIENT_PREFIX}-ue" >/dev/null 2>&1 || true
    if [ "$WARMUP" -gt 0 ] && [ "$real_duration" -ne "$DURATION" ]; then
        docker run --rm \
            --name "${CLIENT_PREFIX}-ue" \
            --network container:ue-embb \
            "$IPERF_IMAGE" \
            -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" \
            "${reverse_arg[@]}" \
            -B "$EMBB_IP" -t "$WARMUP" -P "$flows" >/dev/null 2>&1 || true
    fi

    before=$(ogstun_bytes "$counter_name")
    docker rm -f "${CLIENT_PREFIX}-ue" >/dev/null 2>&1 || true
    output=$(docker run --rm \
        --name "${CLIENT_PREFIX}-ue" \
        --network container:ue-embb \
        "$IPERF_IMAGE" \
        -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" \
        "${reverse_arg[@]}" \
        -B "$EMBB_IP" -t "$real_duration" -P "$flows" 2>&1 || true)
    after=$(ogstun_bytes "$counter_name")

    mbps=$(printf "%s\n" "$output" | iperf_mbps)
    tunnel_mbps=$(awk -v before="$before" -v after="$after" -v seconds="$DURATION" \
        -v real_duration="$real_duration" \
        'BEGIN {printf "%.2f", (after - before) * 8 / real_duration / 1000000}')

    if [ "$mode" = "download" ] && [ "$tunnel_mbps" != "n/a" ]; then
        DOWNLOAD_RESULTS+=("$tunnel_mbps")
    elif [ "$mode" = "upload" ] && [ "$tunnel_mbps" != "n/a" ]; then
        UPLOAD_RESULTS+=("$tunnel_mbps")
    fi

    printf "%-12s %-6s %-14s %-14s %-10s\n" "$mode" "$flows" "$mbps" "$tunnel_mbps" "$counter_name"
}

max_result() {
    printf "%s\n" "$@" | awk '
      $1 ~ /^[0-9.]+$/ && $1 > max {max = $1}
      END {
        if (max == "") print "n/a";
        else printf "%.2f", max
      }'
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
echo "Warm-up    : ${WARMUP}s per tunnel test"
echo
echo "Route from ue-embb to server through uesimtun0:"
docker exec ue-embb ip route get "$IPERF_SERVER_IP" oif uesimtun0 from "$EMBB_IP" 2>/dev/null || true
echo "Route selected by source IP without forcing oif:"
docker exec ue-embb ip route get "$IPERF_SERVER_IP" from "$EMBB_IP" 2>/dev/null || true
echo

echo "[1] Docker bridge baseline, not forced through 5G tunnel"
for flows in $FLOWS; do
    result=$(run_bridge_baseline "$CORE_NETWORK" "$flows" | iperf_mbps)
    printf "bridge       %-6s %-14s %-14s\n" "$flows" "$result" "n/a"
done

echo
echo "[2] 5G tunnel tests"
printf "%-12s %-6s %-14s %-14s %-10s\n" "mode" "flows" "iperf_mbps" "ogstun_mbps" "counter"
for flows in $FLOWS; do
    run_tunnel_test "$flows" "upload"
    run_tunnel_test "$flows" "download"
done

echo
UPLOAD_MAX=$(max_result "${UPLOAD_RESULTS[@]}")
DOWNLOAD_MAX=$(max_result "${DOWNLOAD_RESULTS[@]}")
RECOMMENDED_PARENT=$(awk -v up="$UPLOAD_MAX" -v down="$DOWNLOAD_MAX" 'BEGIN {
  if (up == "n/a" || down == "n/a") print "n/a";
  else {
    ceiling = (up < down ? up : down) * 0.8;
    if (ceiling < 5) ceiling = 5;
    printf "%.0fmbit", ceiling;
  }
}')
ASYMMETRY=$(awk -v up="$UPLOAD_MAX" -v down="$DOWNLOAD_MAX" 'BEGIN {
  if (up == "n/a" || down == "n/a" || down <= 0) print "n/a";
  else printf "%.2fx", up / down;
}')

echo
echo "============================================================"
echo "  Summary - measured tunnel ceiling"
echo "============================================================"
echo "Upload ceiling   : $UPLOAD_MAX Mbps"
echo "Download ceiling : $DOWNLOAD_MAX Mbps"
echo "UL/DL asymmetry  : $ASYMMETRY"
echo "Suggested parent : $RECOMMENDED_PARENT"
echo "                  Use the lower stable tunnel direction, not bridge speed."
echo
echo "Interpretation:"
echo "- bridge high, tunnel low: bottleneck is UPF/GTP/VM CPU, not iperf3."
echo "- upload high, download low: reverse/downlink path or UPF TX queue is the bottleneck."
echo "- throughput drops as flows increase: parallel TCP is overloading the userspace GTP path."
echo "- reverse download drops with many flows: TCP ACK/uplink feedback can double the GTP scheduling pressure."
echo "- upload uses ogstun RX and download uses ogstun TX; compare each mode with its matching counter."
echo "- iperf_mbps and ogstun_mbps should be close; if not, the traffic is not fully on the tunnel path."
