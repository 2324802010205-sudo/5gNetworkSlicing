#!/bin/bash
set -euo pipefail

DURATION="${DURATION:-120}"
VIDEO_URL="${VIDEO_URL:-https://speed.cloudflare.com/__down?bytes=500000000}"
PING_TARGET="${PING_TARGET:-1.1.1.1}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
EMBB_LOG="${EMBB_LOG:-/tmp/embb-video-traffic.log}"
CURL_TLS_OPT="${CURL_TLS_OPT:---insecure}"

cleanup() {
    docker exec ue-embb pkill -f "curl -L --interface uesimtun0" >/dev/null 2>&1 || true
    docker exec ue-embb pkill -f "wget -T 30 -O /dev/null" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running. Start the lab with: docker compose up -d" >&2
        exit 1
    fi
}

ue_ip() {
    docker exec "$1" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

byte_counter() {
    docker exec "$1" awk '$1 ~ /ogstun:/ {print $2, $10}' /proc/net/dev
}

delta_mbps() {
    awk -v b1="$1" -v b2="$2" 'BEGIN { printf "%.2f", (b2 - b1) * 8 / 1000000 }'
}

echo "============================================================"
echo "  5G slicing real demo: eMBB video/web + URLLC latency"
echo "============================================================"
echo

for c in upf-embb upf-urllc ue-embb ue-urllc; do
    need_container "$c"
done

echo "[1/5] Applying slice resource profiles"
bash ./fix-upf.sh >/dev/null
echo "      eMBB : 150 Mbps rate, 180 Mbps burst ceiling, about 18 ms radio delay"
echo "      URLLC: 20 Mbps rate, 25 Mbps ceiling, about 3 ms low-jitter delay"

EMBB_IP=$(ue_ip ue-embb)
URLLC_IP=$(ue_ip ue-urllc)

if [ -z "$EMBB_IP" ] || [ -z "$URLLC_IP" ]; then
    echo "One UE tunnel is missing. Run: bash ./check-5g.sh" >&2
    exit 1
fi

echo
echo "[2/5] UE tunnel IPs"
echo "      eMBB  uesimtun0: $EMBB_IP"
echo "      URLLC uesimtun0: $URLLC_IP"

echo
echo "[3/5] Optional eMBB SOCKS5 proxy for browser/YouTube"
if docker exec ue-embb sh -lc "command -v microsocks >/dev/null 2>&1"; then
    docker exec -d ue-embb sh -lc "pkill microsocks >/dev/null 2>&1 || true; microsocks -i 0.0.0.0 -p $SOCKS_PORT"
    echo "      SOCKS5 proxy inside ue-embb: $EMBB_IP:$SOCKS_PORT"
    echo "      Use it for YouTube if your host can reach the UE tunnel address."
else
    echo "      microsocks is not installed in ue-embb; continuing with curl video-like traffic."
fi

echo
echo "[4/5] Starting eMBB video-like download and URLLC probe"
echo "      eMBB URL : $VIDEO_URL"
echo "      curl TLS option: $CURL_TLS_OPT"
echo "      URLLC ping target: $PING_TARGET"
echo "      Duration : ${DURATION}s"
echo "      eMBB traffic log inside ue-embb: $EMBB_LOG"
echo
printf "%-7s %-13s %-13s %-13s %-18s\n" "Time" "eMBB DL" "eMBB UL" "URLLC RTT" "URLLC loss"
printf "%-7s %-13s %-13s %-13s %-18s\n" "------" "--------" "--------" "---------" "----------"

docker exec ue-embb sh -lc "rm -f '$EMBB_LOG'; touch '$EMBB_LOG'"

if docker exec ue-embb sh -lc "command -v curl >/dev/null 2>&1"; then
    docker exec -d ue-embb sh -lc \
        "while true; do date >> '$EMBB_LOG'; curl -4 $CURL_TLS_OPT -L --interface uesimtun0 --connect-timeout 5 --max-time 30 --speed-time 10 --speed-limit 1024 -o /dev/null -w 'http_code=%{http_code} bytes=%{size_download} speed=%{speed_download}\n' '$VIDEO_URL' >> '$EMBB_LOG' 2>&1 || echo \"curl failed exit=\$?\" >> '$EMBB_LOG'; sleep 1; done"
elif docker exec ue-embb sh -lc "command -v wget >/dev/null 2>&1"; then
    docker exec -d ue-embb sh -lc \
        "while true; do date >> '$EMBB_LOG'; wget -4 -T 30 -O /dev/null '$VIDEO_URL' >> '$EMBB_LOG' 2>&1 || echo 'wget failed exit='$? >> '$EMBB_LOG'; sleep 1; done"
else
    echo "ue-embb has no curl/wget, so eMBB traffic generation cannot start." >&2
    echo "Install curl in the UE image or use the browser SOCKS5 path from start-5g-youtube.sh." >&2
    exit 1
fi

END=$((SECONDS + DURATION))
ZERO_WARNED=0
while [ "$SECONDS" -lt "$END" ]; do
    read -r ERX1 ETX1 < <(byte_counter upf-embb)
    sleep 1
    read -r ERX2 ETX2 < <(byte_counter upf-embb)

    EMB_UP=$(delta_mbps "$ERX1" "$ERX2")
    EMB_DOWN=$(delta_mbps "$ETX1" "$ETX2")
    PING_LINE=$(docker exec ue-urllc ping -I uesimtun0 "$PING_TARGET" -c 5 -i 0.2 -W 1 -q 2>/dev/null || true)
    LOSS=$(printf "%s\n" "$PING_LINE" | awk -F, '/packet loss/ {gsub(/^ +| +$/, "", $3); print $3}')
    RTT=$(printf "%s\n" "$PING_LINE" | awk -F'/' '/rtt|round-trip/ {printf "%.2f ms", $5}')
    [ -n "${LOSS:-}" ] || LOSS="n/a"
    [ -n "${RTT:-}" ] || RTT="timeout"

    printf "%-7s %-13s %-13s %-13s %-18s\n" \
        "${SECONDS}s" "${EMB_DOWN} Mbps" "${EMB_UP} Mbps" "$RTT" "$LOSS"

    if [ "$ZERO_WARNED" -eq 0 ] && [ "$SECONDS" -ge 10 ]; then
        if awk -v down="$EMB_DOWN" -v up="$EMB_UP" 'BEGIN {exit ! (down < 0.01 && up < 0.01)}'; then
            ZERO_WARNED=1
            echo
            echo "WARN: eMBB is still 0 Mbps. Last ue-embb traffic log lines:"
            docker exec ue-embb sh -lc "tail -n 8 '$EMBB_LOG' 2>/dev/null || true"
            echo
        fi
    fi
done

docker exec ue-embb pkill -f "curl -L --interface uesimtun0" >/dev/null 2>&1 || true
docker exec ue-embb pkill -f "wget -T 30 -O /dev/null" >/dev/null 2>&1 || true

echo
echo "[5/5] Done"
echo "Use Grafana -> 5G Lab -> 5G Network Slicing to compare eMBB throughput and URLLC behavior."
