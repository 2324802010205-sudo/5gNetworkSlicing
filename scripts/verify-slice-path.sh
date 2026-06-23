#!/bin/bash
set -euo pipefail

IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
EMBB_SERVER="${EMBB_SERVER_IP:-172.20.0.221}"
EMBB_PORT="${EMBB_PORT:-5201}"
EMBB_PARALLEL="${EMBB_PARALLEL:-2}"
URLLC_SERVER="${URLLC_SERVER_IP:-172.20.0.222}"
URLLC_PORT="${URLLC_PORT:-5202}"
EMBB_DURATION="${EMBB_DURATION:-8}"
URLLC_DURATION="${URLLC_DURATION:-8}"
URLLC_BITRATE="${URLLC_BITRATE:-200K}"
URLLC_PACKET_SIZE="${URLLC_PACKET_SIZE:-128}"
REPORT_DIR="${REPORT_DIR:-reports}"
REPORT_FILE="${REPORT_FILE:-$REPORT_DIR/slice-path-verification.txt}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
CAPTURE_DIR="/tmp/slice-path-$RUN_ID"
FAIL=0
WARN=0

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "FAIL: container $name is not running"
        FAIL=$((FAIL+1))
        return 1
    fi
    return 0
}

need_tcpdump() {
    local name="$1"
    if docker exec "$name" sh -c 'command -v timeout >/dev/null 2>&1 && command -v tcpdump >/dev/null 2>&1'; then
        return 0
    fi
    echo "FAIL: timeout/tcpdump is not available in $name"
    FAIL=$((FAIL+1))
    return 1
}

ue_ip() {
    docker exec "$1" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

check_route() {
    local ue="$1"
    local target="$2"
    local route

    route=$(docker exec "$ue" ip route get "$target" 2>/dev/null || true)
    echo "$ue route to $target: $route"
    if echo "$route" | grep -q 'dev uesimtun0'; then
        echo "PASS: $ue route to $target goes through uesimtun0"
    elif echo "$route" | grep -q 'dev eth0'; then
        echo "FAIL: $ue route to $target goes through eth0"
        FAIL=$((FAIL+1))
    else
        echo "WARN: $ue route to $target is not clear"
        WARN=$((WARN+1))
    fi
}

start_capture() {
    local upf="$1"
    local outfile="$2"
    local filter="$3"

    docker exec "$upf" sh -c "timeout 20 tcpdump -n -i any -c 20 '$filter' 2>/dev/null" > "$outfile" &
    echo $!
}

wait_capture() {
    local pid="$1"
    wait "$pid" || true
}

observed() {
    local file="$1"
    [ -s "$file" ] && grep -Eq 'IP|IP6' "$file"
}

record_path_result() {
    local label="$1"
    local expected_file="$2"
    local wrong_file="$3"
    local expected_msg="$4"
    local wrong_msg="$5"

    if observed "$expected_file"; then
        echo "PASS: $expected_msg"
    else
        echo "FAIL: $expected_msg not observed"
        FAIL=$((FAIL+1))
    fi

    if observed "$wrong_file"; then
        echo "WARN: $wrong_msg"
        WARN=$((WARN+1))
        echo "$label unexpected capture sample:"
        sed -n '1,8p' "$wrong_file"
    else
        echo "PASS: no $label packets observed on the wrong UPF"
    fi
}

mkdir -p "$REPORT_DIR" "$CAPTURE_DIR"
exec > >(tee "$REPORT_FILE") 2>&1

echo "Slice path verification"
echo "Report: $REPORT_FILE"
echo "Run ID: $RUN_ID"
echo

docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server >/dev/null
for c in ue-embb ue-urllc upf-embb upf-urllc embb-iperf-server urllc-iperf-server; do
    need_container "$c"
done
need_tcpdump upf-embb
need_tcpdump upf-urllc

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "FAIL: prerequisites are not satisfied"
    exit 1
fi

EMBB_IP=$(ue_ip ue-embb)
URLLC_IP=$(ue_ip ue-urllc)
if [ -z "$EMBB_IP" ]; then
    echo "FAIL: ue-embb has no uesimtun0 IP"
    FAIL=$((FAIL+1))
fi
if [ -z "$URLLC_IP" ]; then
    echo "FAIL: ue-urllc has no uesimtun0 IP"
    FAIL=$((FAIL+1))
fi
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

echo "ue-embb uesimtun0 IP: $EMBB_IP"
echo "ue-urllc uesimtun0 IP: $URLLC_IP"

docker exec ue-embb ip route replace "$EMBB_SERVER/32" dev uesimtun0 src "$EMBB_IP" 2>/dev/null || true
docker exec ue-urllc ip route replace "$URLLC_SERVER/32" dev uesimtun0 src "$URLLC_IP" 2>/dev/null || true
check_route ue-embb "$EMBB_SERVER"
check_route ue-urllc "$URLLC_SERVER"

echo
echo "Running short eMBB path test"
EMBB_FILTER="host $EMBB_IP or host $EMBB_SERVER"
EMBB_ON_EMBB="$CAPTURE_DIR/embb-on-upf-embb.log"
EMBB_ON_URLLC="$CAPTURE_DIR/embb-on-upf-urllc.log"
PID1=$(start_capture upf-embb "$EMBB_ON_EMBB" "$EMBB_FILTER")
PID2=$(start_capture upf-urllc "$EMBB_ON_URLLC" "$EMBB_FILTER")
sleep 2
docker run --rm --network container:ue-embb "$IMAGE" \
    -c "$EMBB_SERVER" -p "$EMBB_PORT" -B "$EMBB_IP" -P "$EMBB_PARALLEL" -t "$EMBB_DURATION" -R >/dev/null
wait_capture "$PID1"
wait_capture "$PID2"
record_path_result "eMBB" "$EMBB_ON_EMBB" "$EMBB_ON_URLLC" \
    "eMBB packets observed on upf-embb" \
    "eMBB packets observed on upf-urllc"

echo
echo "Running short URLLC path test"
URLLC_FILTER="host $URLLC_IP or host $URLLC_SERVER"
URLLC_ON_URLLC="$CAPTURE_DIR/urllc-on-upf-urllc.log"
URLLC_ON_EMBB="$CAPTURE_DIR/urllc-on-upf-embb.log"
PID3=$(start_capture upf-urllc "$URLLC_ON_URLLC" "$URLLC_FILTER")
PID4=$(start_capture upf-embb "$URLLC_ON_EMBB" "$URLLC_FILTER")
sleep 2
docker run --rm --network container:ue-urllc "$IMAGE" \
    -c "$URLLC_SERVER" -p "$URLLC_PORT" -B "$URLLC_IP" \
    -u -b "$URLLC_BITRATE" -l "$URLLC_PACKET_SIZE" -t "$URLLC_DURATION" >/dev/null
wait_capture "$PID3"
wait_capture "$PID4"
record_path_result "URLLC" "$URLLC_ON_URLLC" "$URLLC_ON_EMBB" \
    "URLLC packets observed on upf-urllc" \
    "URLLC packets observed on upf-embb"

echo
echo "Summary: WARN=$WARN FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
