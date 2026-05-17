#!/bin/bash
set -euo pipefail

DURATION="${DURATION:-60}"
STABILITY_DURATION="${STABILITY_DURATION:-300}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
EMBB_PARALLEL="${EMBB_PARALLEL:-4}"
URLLC_TARGET="${URLLC_TARGET:-10.46.0.1}"
PING_COUNT="${PING_COUNT:-50}"
PING_INTERVAL="${PING_INTERVAL:-0.1}"
IPERF_IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
IPERF_SERVER="${IPERF_SERVER:-embb-iperf-server}"
IPERF_SERVER_IP="${IPERF_SERVER_IP:-172.20.0.221}"
IPERF_PORT="${IPERF_PORT:-5201}"
REPORT_DIR="${REPORT_DIR:-reports}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
REPORT_FILE="$REPORT_DIR/5g-resource-optimization-$RUN_ID.md"
CSV_FILE="$REPORT_DIR/5g-resource-optimization-$RUN_ID.csv"
STABILITY_CSV="$REPORT_DIR/5g-resource-optimization-stability-$RUN_ID.csv"
IPERF_CLIENT_NAME="embb-resource-load-$RUN_ID"

cleanup() {
    docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
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

ensure_iperf_server() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$IPERF_SERVER" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Starting $IPERF_SERVER..."
        docker compose up -d "$IPERF_SERVER" >/dev/null
    fi
}

ue_ip() {
    docker exec "$1" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

upf_counter() {
    local upf="$1"
    local field="$2"
    docker exec "$upf" awk -v field="$field" '$1 ~ /ogstun:/ {print $field}' /proc/net/dev
}

measure_counter_mbps() {
    local upf="$1"
    local field="$2"
    local seconds="$3"
    local before after
    before=$(upf_counter "$upf" "$field")
    sleep "$seconds"
    after=$(upf_counter "$upf" "$field")
    awk -v before="$before" -v after="$after" -v seconds="$seconds" \
        'BEGIN {printf "%.2f", (after - before) * 8 / seconds / 1000000}'
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

field() {
    echo "$1" | awk -F, -v idx="$2" '{print $idx}'
}

ratio() {
    awk -v base="$1" -v load="$2" 'BEGIN {
      if (base == "timeout" || load == "timeout" || base <= 0) print "n/a";
      else printf "%.2f", load / base
    }'
}

start_embb_download() {
    docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
    docker run -d --rm \
        --name "$IPERF_CLIENT_NAME" \
        --network container:ue-embb \
        "$IPERF_IMAGE" \
        -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" -R \
        -B "$EMBB_IP" -P "$EMBB_PARALLEL" -t "$1" \
        >/dev/null
}

stop_embb_download() {
    docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
}

echo "============================================================"
echo "  5G network slicing resource optimization benchmark"
echo "============================================================"
echo

ensure_iperf_server
for c in upf-embb upf-urllc ue-embb ue-urllc "$IPERF_SERVER"; do
    need_container "$c"
done

echo "[1/6] Applying scaled resource profiles"
bash ./fix-upf.sh >/dev/null 2>&1
echo "      eMBB : 12 Mbps guaranteed, 15 Mbps ceiling"
echo "      URLLC: 4 Mbps guaranteed, 8 Mbps ceiling, low queue"

EMBB_IP=$(ue_ip ue-embb)
URLLC_IP=$(ue_ip ue-urllc)
if [ -z "$EMBB_IP" ] || [ -z "$URLLC_IP" ]; then
    echo "One UE tunnel is missing. Run: bash ./check-5g.sh" >&2
    exit 1
fi

mkdir -p "$REPORT_DIR"

echo
echo "[2/6] Preflight"
echo "      eMBB UE : $EMBB_IP"
echo "      URLLC UE: $URLLC_IP"
echo "      eMBB server: ${IPERF_SERVER_IP}:${IPERF_PORT}"
echo "      URLLC target: $URLLC_TARGET"
echo "      eMBB parallel flows: $EMBB_PARALLEL"
echo
docker exec ue-embb ip route get "$IPERF_SERVER_IP" oif uesimtun0 from "$EMBB_IP" 2>/dev/null || true

echo
echo "[3/6] Scenario A - URLLC idle SLA"
IDLE_CSV=$(ping_urllc)
IDLE_AVG=$(field "$IDLE_CSV" 2)
IDLE_JITTER=$(field "$IDLE_CSV" 4)
IDLE_LOSS=$(field "$IDLE_CSV" 5)
echo "      avg=$IDLE_AVG ms, jitter=$IDLE_JITTER ms, loss=$IDLE_LOSS"

echo
echo "[4/6] Scenario B - eMBB-only throughput under scaled ceiling"
start_embb_download "$((DURATION + 5))"
sleep 3
EMBB_ONLY_MBPS=$(measure_counter_mbps upf-embb 10 "$DURATION")
stop_embb_download
echo "      eMBB downlink=$EMBB_ONLY_MBPS Mbps"

echo
echo "[5/6] Scenario C - URLLC SLA while eMBB is saturated"
start_embb_download "$((DURATION + 20))"
sleep 3
LOAD_EMBB_MBPS=$(measure_counter_mbps upf-embb 10 "$DURATION")
LOAD_CSV=$(ping_urllc)
stop_embb_download
LOAD_AVG=$(field "$LOAD_CSV" 2)
LOAD_JITTER=$(field "$LOAD_CSV" 4)
LOAD_LOSS=$(field "$LOAD_CSV" 5)
LATENCY_RATIO=$(ratio "$IDLE_AVG" "$LOAD_AVG")
JITTER_RATIO=$(ratio "$IDLE_JITTER" "$LOAD_JITTER")
echo "      eMBB downlink=$LOAD_EMBB_MBPS Mbps"
echo "      URLLC avg=$LOAD_AVG ms, jitter=$LOAD_JITTER ms, loss=$LOAD_LOSS"
echo "      isolation ratios: latency=$LATENCY_RATIO, jitter=$JITTER_RATIO"

echo
echo "[6/6] Scenario D - sustained stability"
echo "sample,elapsed_s,embb_downlink_mbps,urllc_avg_ms,urllc_jitter_ms,urllc_loss" > "$STABILITY_CSV"
start_embb_download "$((STABILITY_DURATION + 30))"
END=$((SECONDS + STABILITY_DURATION))
SAMPLE=0
while [ "$SECONDS" -lt "$END" ]; do
    SAMPLE=$((SAMPLE + 1))
    BEFORE=$(upf_counter upf-embb 10)
    sleep "$SAMPLE_INTERVAL"
    AFTER=$(upf_counter upf-embb 10)
    SHORT_PING=$(docker exec ue-urllc ping -I uesimtun0 "$URLLC_TARGET" -c 5 -i 0.2 -q 2>/dev/null || true)
    SAMPLE_MBPS=$(awk -v before="$BEFORE" -v after="$AFTER" -v seconds="$SAMPLE_INTERVAL" \
        'BEGIN {printf "%.2f", (after - before) * 8 / seconds / 1000000}')
    SAMPLE_CSV=$(printf "%s\n" "$SHORT_PING" | parse_ping)
    SAMPLE_AVG=$(field "$SAMPLE_CSV" 2)
    SAMPLE_JITTER=$(field "$SAMPLE_CSV" 4)
    SAMPLE_LOSS=$(field "$SAMPLE_CSV" 5)
    ELAPSED=$((SAMPLE * SAMPLE_INTERVAL))
    echo "$SAMPLE,$ELAPSED,$SAMPLE_MBPS,$SAMPLE_AVG,$SAMPLE_JITTER,$SAMPLE_LOSS" >> "$STABILITY_CSV"
    printf "      %4ss  eMBB=%s Mbps  URLLC avg=%s ms jitter=%s ms loss=%s\n" \
        "$ELAPSED" "$SAMPLE_MBPS" "$SAMPLE_AVG" "$SAMPLE_JITTER" "$SAMPLE_LOSS"
done
stop_embb_download

cat > "$REPORT_FILE" <<EOF_REPORT
# 5G Network Slicing Resource Optimization Benchmark

Run ID: $RUN_ID

## Testbed Scope

This benchmark uses a scaled resource profile because the Open5GS userspace UPF throughput ceiling in this VM is lower than a real 5G data plane. The goal is to validate slice resource behavior: eMBB gets sustained broadband capacity, while uRLLC keeps latency and jitter stable under eMBB saturation.

## Configuration

- eMBB UE IP: $EMBB_IP
- uRLLC UE IP: $URLLC_IP
- eMBB generator: iperf3 reverse TCP, ${IPERF_SERVER_IP}:${IPERF_PORT}
- eMBB parallel flows: $EMBB_PARALLEL
- uRLLC latency target: $URLLC_TARGET
- eMBB profile: 12 Mbps guaranteed, 15 Mbps ceiling
- uRLLC profile: 4 Mbps guaranteed, 8 Mbps ceiling, fq_codel low queue

## Results

| Scenario | Metric | Result |
| --- | --- | ---: |
| uRLLC idle | avg RTT | $IDLE_AVG ms |
| uRLLC idle | jitter/mdev | $IDLE_JITTER ms |
| uRLLC idle | packet loss | $IDLE_LOSS |
| eMBB only | downlink throughput | $EMBB_ONLY_MBPS Mbps |
| eMBB + uRLLC | eMBB downlink throughput | $LOAD_EMBB_MBPS Mbps |
| eMBB + uRLLC | uRLLC avg RTT | $LOAD_AVG ms |
| eMBB + uRLLC | uRLLC jitter/mdev | $LOAD_JITTER ms |
| eMBB + uRLLC | uRLLC packet loss | $LOAD_LOSS |

## Isolation Indicators

- Latency isolation ratio, load / idle: $LATENCY_RATIO
- Jitter isolation ratio, load / idle: $JITTER_RATIO

## Interpretation

A ratio close to 1.00 means uRLLC remains stable while eMBB consumes its allocated broadband slice. If the absolute eMBB throughput is below 100-150 Mbps, interpret that as a limitation of the softwarized VM UPF data plane, not as a failure of the resource isolation policy.

Stability samples: $STABILITY_CSV
EOF_REPORT

cat > "$CSV_FILE" <<EOF_CSV
run_id,embb_only_mbps,embb_load_mbps,urllc_idle_avg_ms,urllc_load_avg_ms,urllc_idle_jitter_ms,urllc_load_jitter_ms,urllc_idle_loss,urllc_load_loss,latency_ratio,jitter_ratio
$RUN_ID,$EMBB_ONLY_MBPS,$LOAD_EMBB_MBPS,$IDLE_AVG,$LOAD_AVG,$IDLE_JITTER,$LOAD_JITTER,$IDLE_LOSS,$LOAD_LOSS,$LATENCY_RATIO,$JITTER_RATIO
EOF_CSV

echo
echo "Report: $REPORT_FILE"
echo "CSV   : $CSV_FILE"
echo "Series: $STABILITY_CSV"
