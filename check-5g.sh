#!/bin/bash
set -u

OK=0
WARN=0
FAIL=0

pass() { echo "[OK]   $1"; OK=$((OK+1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

need_container() {
  local name="$1"
  local state
  state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
  if [ "$state" = "running" ]; then
    pass "container $name is running"
  else
    fail "container $name is not running"
  fi
}

check_tunnel() {
  local name="$1"
  local ip
  ip=$(docker exec "$name" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' || true)
  if [ -n "$ip" ]; then
    pass "$name tunnel uesimtun0: $ip"
  else
    fail "$name has no uesimtun0 tunnel"
  fi
}

check_ping() {
  local name="$1"
  if docker exec "$name" ping -I uesimtun0 1.1.1.1 -c 2 -W 3 >/dev/null 2>&1; then
    pass "$name internet ping through 5G tunnel"
  else
    warn "$name cannot ping 1.1.1.1 through uesimtun0"
  fi
}

check_qos() {
  local upf="$1"
  if docker exec "$upf" tc qdisc show dev ogstun 2>/dev/null | grep -Eq 'htb|tbf|netem'; then
    pass "$upf QoS qdisc is configured"
  else
    warn "$upf QoS qdisc not found"
  fi
}

echo "== Docker compose syntax =="
if docker compose config >/dev/null; then
  pass "docker-compose.yaml is valid"
else
  fail "docker-compose.yaml has an error"
fi

echo
echo "== Containers =="
for c in mongo nrf amf smf ausf udm udr pcf upf-embb upf-urllc webui prometheus grafana gnb ue-embb ue-urllc pushgateway node-exporter cadvisor embb-iperf-server; do
  need_container "$c"
done

echo
echo "== UE tunnels =="
check_tunnel ue-embb
check_tunnel ue-urllc

echo
echo "== Slice connectivity =="
check_ping ue-embb
check_ping ue-urllc

echo
echo "== UPF QoS =="
check_qos upf-embb
check_qos upf-urllc

echo
echo "== Prometheus =="
if docker exec prometheus wget -qO- http://localhost:9090/-/ready >/dev/null 2>&1; then
  pass "Prometheus is ready"
else
  warn "Prometheus is not ready yet"
fi

echo
echo "Summary: $OK ok, $WARN warning, $FAIL fail"
[ "$FAIL" -eq 0 ]
