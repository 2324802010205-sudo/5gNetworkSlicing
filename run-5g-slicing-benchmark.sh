#!/bin/bash
set -euo pipefail

DURATION="${DURATION:-60}"
EMBB_MODE="${EMBB_MODE:-iperf3}"
EMBB_URL="${EMBB_URL:-http://172.20.0.220:8080/embb.bin}"
EMBB_PARALLEL="${EMBB_PARALLEL:-4}"
IPERF_IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
IPERF_SERVER_IP="${IPERF_SERVER_IP:-172.20.0.221}"
IPERF_PORT="${IPERF_PORT:-5201}"
URLLC_TARGET="${URLLC_TARGET:-10.46.0.1}"
PING_COUNT="${PING_COUNT:-50}"
PING_INTERVAL="${PING_INTERVAL:-0.1}"
REPORT_DIR="${REPORT_DIR:-reports}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
REPORT_FILE="$REPORT_DIR/5g-slicing-benchmark-$RUN_ID.md"
CSV_FILE="$REPORT_DIR/5g-slicing-benchmark-$RUN_ID.csv"
EMBB_LOG="/tmp/embb-benchmark-load.log"
IPERF_CLIENT_NAME="embb-iperf-client-$RUN_ID"
ACTIVE_EMBB_GENERATOR="http"

cleanup() {
    docker exec ue-embb pkill -f "curl .*${EMBB_URL}" >/dev/null 2>&1 || true
    docker exec ue-embb pkill -f "wget .*${EMBB_URL}" >/dev/null 2>&1 || true
    docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
    docker rm -f "${IPERF_CLIENT_NAME}-precheck" >/dev/null 2>&1 || true
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

ensure_embb_traffic_source() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' embb-traffic-source 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Starting local eMBB traffic source..."
        docker compose up -d embb-traffic-source >/dev/null
    fi
}

ensure_embb_iperf_server() {
    local state
    [ "$EMBB_MODE" != "http" ] || return 1

    state=$(docker inspect -f '{{.State.Status}}' embb-iperf-server 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Starting local eMBB iperf3 server..."
        if ! docker compose up -d embb-iperf-server >/dev/null 2>&1; then
            echo "iperf3 server could not be started; falling back to HTTP load." >&2
            return 1
        fi
    fi

    docker inspect -f '{{.State.Status}}' embb-iperf-server 2>/dev/null | grep -q running
}

ue_ip() {
    docker exec "$1" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

byte_counter() {
    docker exec "$1" awk '$1 ~ /ogstun:/ {print $2, $10}' /proc/net/dev
}

measure_embb_mbps() {
    local seconds="$1"
    local rx1 tx1 rx2 tx2
    read -r rx1 tx1 < <(byte_counter upf-embb)
    sleep "$seconds"
    read -r rx2 tx2 < <(byte_counter upf-embb)
    awk -v before="$tx1" -v after="$tx2" -v seconds="$seconds" \
        'BEGIN {printf "%.2f", (after - before) * 8 / seconds / 1000000}'
}

validate_embb_datapath() {
    local rx1 tx1 rx2 tx2 delta
    docker exec ue-embb sh -lc "rm -f '$EMBB_LOG'; touch '$EMBB_LOG'"
    read -r rx1 tx1 < <(byte_counter upf-embb)

    if [ "$ACTIVE_EMBB_GENERATOR" = "iperf3" ]; then
        docker rm -f "${IPERF_CLIENT_NAME}-precheck" >/dev/null 2>&1 || true
        docker run --rm \
            --name "${IPERF_CLIENT_NAME}-precheck" \
            --network container:ue-embb \
            "$IPERF_IMAGE" \
            -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" -R \
            -P 1 -t 3 -B "$EMBB_IP" >> "$EMBB_LOG" 2>&1 || true
    elif docker exec ue-embb sh -lc "command -v curl >/dev/null 2>&1"; then
        docker exec ue-embb sh -lc \
            "curl -4 -L --interface uesimtun0 --connect-timeout 5 --max-time 5 -o /dev/null '$EMBB_URL' >> '$EMBB_LOG' 2>&1 || true"
    elif docker exec ue-embb sh -lc "command -v wget >/dev/null 2>&1"; then
        docker exec ue-embb sh -lc \
            "wget -4 -T 5 -O /dev/null '$EMBB_URL' >> '$EMBB_LOG' 2>&1 || true"
    else
        echo "ue-embb has no curl/wget, so eMBB datapath cannot be validated." >&2
        exit 1
    fi

    read -r rx2 tx2 < <(byte_counter upf-embb)
    delta=$((tx2 - tx1))
    if [ "$delta" -le 0 ]; then
        echo "eMBB datapath validation failed: upf-embb ogstun TX did not increase." >&2
        echo "This means traffic is not traversing the eMBB UPF/GTP tunnel or the source is unreachable." >&2
        echo "Last eMBB traffic log lines:" >&2
        if [ "$ACTIVE_EMBB_GENERATOR" = "iperf3" ]; then
            (tail -n 12 "$EMBB_LOG" 2>/dev/null || true) >&2
        else
            docker exec ue-embb sh -lc "tail -n 12 '$EMBB_LOG' 2>/dev/null || true" >&2
        fi
        exit 1
    fi

    awk -v bytes="$delta" 'BEGIN {printf "%.2f", bytes / 1000000}'
}

parse_ping() {
    awk '
      /packet loss/ {
        split($0, parts, ",")
        loss = parts[3]
        gsub(/^ +| +$/, "", loss)
      }
      /rtt|round-trip/ {
        split($0, fields, "=")
        split(fields[2], stats, "/")
        min = stats[1] + 0
        avg = stats[2] + 0
        max = stats[3] + 0
        mdev = stats[4] + 0
        seen_rtt = 1
      }
      END {
        if (!seen_rtt) {
          printf "timeout,timeout,timeout,timeout,%s", (loss == "" ? "100% packet loss" : loss)
        } else {
          printf "%.3f,%.3f,%.3f,%.3f,%s", min, avg, max, mdev, loss
        }
      }'
}

ping_urllc() {
    local output
    output=$(docker exec ue-urllc ping -I uesimtun0 "$URLLC_TARGET" -c "$PING_COUNT" -i "$PING_INTERVAL" -q 2>/dev/null || true)
    printf "%s\n" "$output" | parse_ping
}

start_embb_load() {
    docker exec ue-embb sh -lc "rm -f '$EMBB_LOG'; touch '$EMBB_LOG'"

    if [ "$ACTIVE_EMBB_GENERATOR" = "iperf3" ]; then
        docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
        docker run -d --rm \
            --name "$IPERF_CLIENT_NAME" \
            --network container:ue-embb \
            "$IPERF_IMAGE" \
            -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" -R \
            -P "$EMBB_PARALLEL" -t "$((DURATION + 5))" -B "$EMBB_IP" \
            >/dev/null
        return
    fi

    if docker exec ue-embb sh -lc "command -v curl >/dev/null 2>&1"; then
        for _ in $(seq 1 "$EMBB_PARALLEL"); do
            docker exec -d ue-embb sh -lc \
                "while true; do curl -4 -L --interface uesimtun0 --connect-timeout 5 --max-time 30 -o /dev/null '$EMBB_URL' >> '$EMBB_LOG' 2>&1 || echo \"curl failed exit=\$?\" >> '$EMBB_LOG'; done"
        done
    elif docker exec ue-embb sh -lc "command -v wget >/dev/null 2>&1"; then
        for _ in $(seq 1 "$EMBB_PARALLEL"); do
            docker exec -d ue-embb sh -lc \
                "while true; do wget -4 -T 30 -O /dev/null '$EMBB_URL' >> '$EMBB_LOG' 2>&1 || echo \"wget failed exit=\$?\" >> '$EMBB_LOG'; done"
        done
    else
        echo "ue-embb has no curl/wget, so eMBB load cannot start." >&2
        exit 1
    fi
}

metric_field() {
    local csv="$1"
    local index="$2"
    echo "$csv" | awk -F, -v idx="$index" '{print $idx}'
}

ratio() {
    awk -v base="$1" -v load="$2" 'BEGIN {
      if (base == "timeout" || load == "timeout" || base <= 0) print "n/a";
      else printf "%.2f", load / base
    }'
}

echo "============================================================"
echo "  5G slicing benchmark: throughput, latency, jitter, isolation"
echo "============================================================"
echo

if ensure_embb_iperf_server; then
    ACTIVE_EMBB_GENERATOR="iperf3"
else
    ensure_embb_traffic_source
    ACTIVE_EMBB_GENERATOR="http"
fi

for c in upf-embb upf-urllc ue-embb ue-urllc; do
    need_container "$c"
done
if [ "$ACTIVE_EMBB_GENERATOR" = "iperf3" ]; then
    need_container embb-iperf-server
else
    need_container embb-traffic-source
fi

echo "[1/6] Applying QoS profiles"
bash ./fix-upf.sh >/dev/null 2>&1
echo "      eMBB  target: 150 Mbps committed, 180 Mbps burst ceiling"
echo "      URLLC target: 20 Mbps committed, low queue, low jitter"

EMBB_IP=$(ue_ip ue-embb)
URLLC_IP=$(ue_ip ue-urllc)
if [ -z "$EMBB_IP" ] || [ -z "$URLLC_IP" ]; then
    echo "One UE tunnel is missing. Run: bash ./check-5g.sh" >&2
    exit 1
fi

echo
echo "[2/6] Preflight"
echo "      eMBB UE : $EMBB_IP"
echo "      URLLC UE: $URLLC_IP"
if [ "$ACTIVE_EMBB_GENERATOR" = "iperf3" ]; then
    echo "      eMBB source: iperf3 reverse TCP at ${IPERF_SERVER_IP}:${IPERF_PORT}"
else
    echo "      eMBB source: $EMBB_URL"
fi
echo "      URLLC target: $URLLC_TARGET"
echo "      eMBB parallel flows: $EMBB_PARALLEL"
echo
echo "      eMBB route to traffic source with forced tunnel:"
if [ "$ACTIVE_EMBB_GENERATOR" = "iperf3" ]; then
    docker exec ue-embb ip route get "$IPERF_SERVER_IP" oif uesimtun0 from "$EMBB_IP" 2>/dev/null || true
else
    docker exec ue-embb ip route get "$(echo "$EMBB_URL" | awk -F[/:] '{print $4}')" oif uesimtun0 from "$EMBB_IP" 2>/dev/null || true
fi

echo
echo "      Validating eMBB data path through upf-embb/ogstun..."
PRECHECK_MB=$(validate_embb_datapath)
echo "      OK - upf-embb ogstun TX increased by ${PRECHECK_MB} MB"

echo
echo "[3/6] Baseline URLLC latency without eMBB load"
IDLE_CSV=$(ping_urllc)
IDLE_MIN=$(metric_field "$IDLE_CSV" 1)
IDLE_AVG=$(metric_field "$IDLE_CSV" 2)
IDLE_MAX=$(metric_field "$IDLE_CSV" 3)
IDLE_JITTER=$(metric_field "$IDLE_CSV" 4)
IDLE_LOSS=$(metric_field "$IDLE_CSV" 5)
echo "      avg=$IDLE_AVG ms, jitter(mdev)=$IDLE_JITTER ms, loss=$IDLE_LOSS"

echo
echo "[4/6] eMBB full-load throughput"
start_embb_load
sleep 3
EMBB_MBPS=$(measure_embb_mbps "$DURATION")
echo "      eMBB downlink throughput: $EMBB_MBPS Mbps"

echo
echo "[5/6] URLLC latency while eMBB is saturated"
LOAD_CSV=$(ping_urllc)
LOAD_MIN=$(metric_field "$LOAD_CSV" 1)
LOAD_AVG=$(metric_field "$LOAD_CSV" 2)
LOAD_MAX=$(metric_field "$LOAD_CSV" 3)
LOAD_JITTER=$(metric_field "$LOAD_CSV" 4)
LOAD_LOSS=$(metric_field "$LOAD_CSV" 5)
echo "      avg=$LOAD_AVG ms, jitter(mdev)=$LOAD_JITTER ms, loss=$LOAD_LOSS"

cleanup

LATENCY_RATIO=$(ratio "$IDLE_AVG" "$LOAD_AVG")
JITTER_RATIO=$(ratio "$IDLE_JITTER" "$LOAD_JITTER")

mkdir -p "$REPORT_DIR"
cat > "$REPORT_FILE" <<EOF_REPORT
# 5G Network Slicing Benchmark

Run ID: $RUN_ID

## Configuration

- eMBB UE IP: $EMBB_IP
- URLLC UE IP: $URLLC_IP
- eMBB load generator: $ACTIVE_EMBB_GENERATOR
- eMBB HTTP traffic source: $EMBB_URL
- eMBB iperf3 server: ${IPERF_SERVER_IP}:${IPERF_PORT}
- URLLC latency target: $URLLC_TARGET
- eMBB parallel flows: $EMBB_PARALLEL
- eMBB measurement duration: ${DURATION}s
- URLLC ping count: $PING_COUNT
- URLLC ping interval: ${PING_INTERVAL}s

## Results

| Metric | Idle | eMBB Full Load |
| --- | ---: | ---: |
| eMBB downlink throughput | n/a | $EMBB_MBPS Mbps |
| URLLC RTT min | $IDLE_MIN ms | $LOAD_MIN ms |
| URLLC RTT avg | $IDLE_AVG ms | $LOAD_AVG ms |
| URLLC RTT max | $IDLE_MAX ms | $LOAD_MAX ms |
| URLLC jitter/mdev | $IDLE_JITTER ms | $LOAD_JITTER ms |
| URLLC packet loss | $IDLE_LOSS | $LOAD_LOSS |

## Isolation Indicators

- Latency isolation ratio, avg RTT under load / idle: $LATENCY_RATIO
- Jitter isolation ratio, mdev under load / idle: $JITTER_RATIO

Interpretation: lower ratios are better. A ratio close to 1.00 means uRLLC latency stays stable while eMBB is saturated.
EOF_REPORT

cat > "$CSV_FILE" <<EOF_CSV
run_id,embb_mbps,urllc_idle_avg_ms,urllc_load_avg_ms,urllc_idle_jitter_ms,urllc_load_jitter_ms,urllc_idle_loss,urllc_load_loss,latency_ratio,jitter_ratio
$RUN_ID,$EMBB_MBPS,$IDLE_AVG,$LOAD_AVG,$IDLE_JITTER,$LOAD_JITTER,$IDLE_LOSS,$LOAD_LOSS,$LATENCY_RATIO,$JITTER_RATIO
EOF_CSV

echo
echo "[6/6] Summary"
printf "%-34s %s\n" "eMBB downlink throughput:" "$EMBB_MBPS Mbps"
printf "%-34s %s -> %s ms\n" "URLLC avg RTT idle/load:" "$IDLE_AVG" "$LOAD_AVG"
printf "%-34s %s -> %s ms\n" "URLLC jitter idle/load:" "$IDLE_JITTER" "$LOAD_JITTER"
printf "%-34s %s -> %s\n" "URLLC loss idle/load:" "$IDLE_LOSS" "$LOAD_LOSS"
printf "%-34s %s\n" "Latency isolation ratio:" "$LATENCY_RATIO"
printf "%-34s %s\n" "Jitter isolation ratio:" "$JITTER_RATIO"
echo
echo "Report: $REPORT_FILE"
echo "CSV   : $CSV_FILE"
