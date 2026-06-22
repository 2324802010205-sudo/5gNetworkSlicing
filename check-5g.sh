#!/bin/bash
set -u

OK=0
WARN=0
FAIL=0

pass() { printf "[PASS] %s\n" "$1"; OK=$((OK+1)); }
warn() { printf "[WARN] %s\n" "$1"; WARN=$((WARN+1)); }
fail() { printf "[FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); }

container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

need_running() {
  local name="$1"
  if [ "$(container_state "$name")" = "running" ]; then
    pass "$name is running"
  else
    fail "$name is not running"
  fi
}

optional_running() {
  local name="$1"
  if [ "$(container_state "$name")" = "running" ]; then
    pass "$name is running"
  else
    warn "$name is not running (optional profile)"
  fi
}

log_has() {
  local name="$1"
  local pattern="$2"
  docker logs "$name" --tail 300 2>&1 | grep -Eiq "$pattern"
}

check_tunnel() {
  local name="$1"
  local ip
  ip=$(docker exec "$name" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' || true)
  if [ -n "$ip" ]; then
    pass "$name has uesimtun0: $ip"
  else
    fail "$name has no uesimtun0"
  fi
}

check_ping() {
  local name="$1"
  local target="$2"
  if docker exec "$name" ping -I uesimtun0 "$target" -c 2 -W 3 >/dev/null 2>&1; then
    pass "$name ping through uesimtun0 to $target"
  else
    warn "$name cannot ping $target through uesimtun0"
  fi
}

check_qos() {
  local upf="$1"
  if docker exec "$upf" tc qdisc show dev ogstun 2>/dev/null | grep -Eq 'htb|fq_codel|netem|tbf'; then
    pass "$upf has tc policy on ogstun"
  else
    warn "$upf has no tc policy on ogstun"
  fi
}

echo "== Docker =="
if docker ps >/dev/null 2>&1; then
  pass "docker ps works"
else
  fail "docker ps failed"
fi

if docker compose config >/dev/null 2>&1; then
  pass "docker compose config is valid"
else
  fail "docker compose config failed"
fi

echo
echo "== Core containers =="
for c in mongo nrf nssf amf ausf udm udr pcf smf upf-embb upf-urllc gnb ue-embb ue-urllc; do
  need_running "$c"
done

echo
echo "== MongoDB =="
mongo_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' mongo 2>/dev/null || true)
if [ "$mongo_health" = "healthy" ]; then
  pass "mongo is healthy"
elif [ "$mongo_health" = "none" ] && [ "$(container_state mongo)" = "running" ]; then
  warn "mongo is running without health status"
else
  fail "mongo health is ${mongo_health:-unknown}"
fi

echo
echo "== Registration signals =="
if log_has amf 'gNB.*connected|NG setup|NGSetup|SCTP.*connected'; then
  pass "AMF log shows gNB connection"
else
  warn "AMF log does not show a clear gNB connection yet"
fi

if log_has gnb 'NG Setup|connected|Connection setup'; then
  pass "gNB log shows AMF connection"
else
  warn "gNB log does not show a clear AMF connection yet"
fi

for ue in ue-embb ue-urllc; do
  if log_has "$ue" 'Registration.*accepted|registered|PDU Session.*established|Session.*established'; then
    pass "$ue log shows registration/session progress"
  else
    warn "$ue log does not show registration/session progress yet"
  fi
done

if log_has smf 'PFCP.*associated|Session.*established|PDU Session|Created'; then
  pass "SMF log shows PFCP/PDU activity"
else
  warn "SMF log does not show PFCP/PDU activity yet"
fi

echo
echo "== UE tunnels =="
check_tunnel ue-embb
check_tunnel ue-urllc

echo
echo "== Slice connectivity =="
check_ping ue-embb 10.45.0.1
check_ping ue-urllc 10.46.0.1

echo
echo "== UPF QoS =="
check_qos upf-embb
check_qos upf-urllc

echo
echo "== Optional profiles =="
for c in prometheus grafana pushgateway node-exporter cadvisor embb-iperf-server urllc-iperf-server mqtt-server webui; do
  optional_running "$c"
done

echo
echo "Summary: $OK PASS, $WARN WARN, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
