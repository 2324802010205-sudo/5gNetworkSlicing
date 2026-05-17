#!/bin/bash
set -e

echo "=================================================="
echo "   5G Network Slicing - Fix UPF"
echo "   Open5GS v2.7.5 + Docker"
echo "=================================================="

apply_embb_qos() {
  if docker exec upf-embb test -f /scripts/apply-slice-qos.sh; then
    docker exec upf-embb /bin/bash /scripts/apply-slice-qos.sh embb ogstun >/dev/null
  else
    docker exec upf-embb tc qdisc del dev ogstun root 2>/dev/null || true
    docker exec upf-embb tc qdisc add dev ogstun root handle 1: htb default 10 r2q 1000
    docker exec upf-embb tc class add dev ogstun parent 1: classid 1:10 htb \
      rate 16mbit ceil 20mbit burst 128k cburst 128k prio 2
    docker exec upf-embb tc qdisc add dev ogstun parent 1:10 handle 10: netem \
      delay 8ms 2ms distribution normal loss 0% limit 1000
  fi
}

apply_urllc_qos() {
  if docker exec upf-urllc test -f /scripts/apply-slice-qos.sh; then
    docker exec upf-urllc /bin/bash /scripts/apply-slice-qos.sh urllc ogstun >/dev/null
  else
    docker exec upf-urllc tc qdisc del dev ogstun root 2>/dev/null || true
    docker exec upf-urllc tc qdisc add dev ogstun root handle 1: htb default 10 r2q 1000
    docker exec upf-urllc tc class add dev ogstun parent 1: classid 1:10 htb \
      rate 20mbit ceil 25mbit burst 32k cburst 32k prio 0
    docker exec upf-urllc tc qdisc add dev ogstun parent 1:10 handle 10: netem \
      delay 2ms 0.3ms distribution normal loss 0.01% limit 20
    docker exec upf-urllc tc qdisc add dev ogstun parent 10:1 handle 20: fq_codel \
      limit 64 target 1ms interval 10ms quantum 300 ecn
  fi
}

echo ""
echo "[1/7] Fixing IP - UPF-eMBB (10.45.0.1/16)..."
docker exec upf-embb ip addr del 10.45.0.1/16 dev ogstun 2>/dev/null || true
docker exec upf-embb ip addr add 10.45.0.1/16 dev ogstun
echo "      OK"

echo "[2/7] Fixing NAT - UPF-eMBB..."
docker exec upf-embb iptables -t nat -F POSTROUTING 2>/dev/null || true
docker exec upf-embb iptables -t nat -A POSTROUTING \
  -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
echo "      OK"

echo "[3/7] Fixing QoS - UPF-eMBB (scaled lab profile: 16Mbps rate, 20Mbps ceiling)..."
apply_embb_qos
echo "      OK"

echo ""
echo "[4/7] Fixing IP - UPF-uRLLC (10.46.0.1/16)..."
docker exec upf-urllc ip addr del 10.46.0.1/16 dev ogstun 2>/dev/null || true
docker exec upf-urllc ip addr del 10.45.0.1/16 dev ogstun 2>/dev/null || true
docker exec upf-urllc ip addr add 10.46.0.1/16 dev ogstun
echo "      OK"

echo "[5/7] Fixing NAT - UPF-uRLLC..."
docker exec upf-urllc iptables -t nat -F POSTROUTING 2>/dev/null || true
docker exec upf-urllc iptables -t nat -A POSTROUTING \
  -s 10.46.0.0/16 ! -o ogstun -j MASQUERADE
echo "      OK"

echo "[6/7] Fixing QoS - UPF-uRLLC (scaled lab profile: 4Mbps rate, 8Mbps ceiling, low jitter)..."
apply_urllc_qos
echo "      OK"

echo ""
echo "[7/7] Restarting UEs to refresh GTP-U sessions..."
docker compose restart ue-embb ue-urllc >/dev/null
sleep 15
echo "      OK"

echo ""
echo "=================================================="
echo "   VERIFY"
echo "=================================================="

echo ""
echo "--- IP ogstun ---"
echo -n "UPF-eMBB  : "
docker exec upf-embb ip addr show ogstun | awk '/inet / {print $2}'
echo -n "UPF-uRLLC : "
docker exec upf-urllc ip addr show ogstun | awk '/inet / {print $2}'

echo ""
echo "--- TC Rules ---"
echo -n "UPF-eMBB  : "
docker exec upf-embb tc qdisc show dev ogstun | grep -E "htb|netem" || echo "NOT FOUND"
echo -n "UPF-uRLLC : "
docker exec upf-urllc tc qdisc show dev ogstun | grep -E "htb|netem" || echo "NOT FOUND"

echo ""
echo "--- UE Tunnel IP ---"
echo -n "UE-eMBB  : "
docker exec ue-embb ip addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' || echo "TUNNEL DOWN"
echo -n "UE-uRLLC : "
docker exec ue-urllc ip addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' || echo "TUNNEL DOWN"

echo ""
echo "--- Ping Test ---"
echo -n "UE-eMBB  -> 1.1.1.1 : "
docker exec ue-embb ping -I uesimtun0 1.1.1.1 -c 2 -W 3 -q 2>/dev/null \
  | grep "packet loss" | awk '{print $6" loss"}' || echo "FAIL"
echo -n "UE-uRLLC -> 1.1.1.1 : "
docker exec ue-urllc ping -I uesimtun0 1.1.1.1 -c 2 -W 3 -q 2>/dev/null \
  | grep "packet loss" | awk '{print $6" loss"}' || echo "FAIL"

echo ""
echo "DONE"
