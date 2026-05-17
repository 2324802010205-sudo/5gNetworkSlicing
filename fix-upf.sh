#!/bin/bash
set -e

echo "=================================================="
echo "   5G Network Slicing - Fix UPF"
echo "   Open5GS v2.7.5 + Docker"
echo "=================================================="

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

echo "[3/7] Fixing QoS - UPF-eMBB (100Mbps, 20ms)..."
docker exec upf-embb tc qdisc del dev ogstun root 2>/dev/null || true
docker exec upf-embb tc qdisc add dev ogstun root handle 1: htb default 10
docker exec upf-embb tc class add dev ogstun parent 1: classid 1:10 htb rate 100mbit ceil 100mbit
docker exec upf-embb tc qdisc add dev ogstun parent 1:10 handle 10: netem delay 20ms
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

echo "[6/7] Fixing QoS - UPF-uRLLC (20Mbps, low latency)..."
docker exec upf-urllc tc qdisc del dev ogstun root 2>/dev/null || true
docker exec upf-urllc tc qdisc add dev ogstun root handle 1: htb default 10
docker exec upf-urllc tc class add dev ogstun parent 1: classid 1:10 htb \
  rate 20mbit ceil 20mbit burst 1600b prio 0
docker exec upf-urllc tc qdisc add dev ogstun parent 1:10 handle 10: netem delay 5ms
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
