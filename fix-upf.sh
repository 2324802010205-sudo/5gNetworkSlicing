#!/bin/bash
set -e

echo "=================================================="
echo "   5G Network Slicing — Fix UPF Script v2"
echo "   Open5GS v2.7.5 + Docker"
echo "=================================================="

# ── UPF-eMBB ────────────────────────────────────────
echo ""
echo "[1/6] Fixing IP — UPF-eMBB (10.45.0.1/16)..."
docker exec upf-embb ip addr del 10.45.0.1/16 dev ogstun 2>/dev/null || true
docker exec upf-embb ip addr add 10.45.0.1/16 dev ogstun
echo "      OK"

echo "[2/6] Fixing NAT — UPF-eMBB..."
docker exec upf-embb iptables -t nat -F POSTROUTING 2>/dev/null || true
docker exec upf-embb iptables -t nat -A POSTROUTING \
  -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
echo "      OK"

echo "[3/6] Fixing TC/QoS — UPF-eMBB (TBF 100Mbps)..."
docker exec upf-embb tc qdisc del dev ogstun root 2>/dev/null || true
docker exec upf-embb tc qdisc add dev ogstun root tbf \
  rate 100mbit burst 10mb latency 50ms
echo "      OK"

# ── UPF-uRLLC — dùng .254 tránh conflict với UE ────
echo ""
echo "[4/6] Fixing IP — UPF-uRLLC (10.46.0.254/16)..."
docker exec upf-urllc ip addr del 10.46.0.1/16   dev ogstun 2>/dev/null || true
docker exec upf-urllc ip addr del 10.46.0.254/16 dev ogstun 2>/dev/null || true
docker exec upf-urllc ip addr del 10.45.0.1/16   dev ogstun 2>/dev/null || true
docker exec upf-urllc ip addr add 10.46.0.254/16 dev ogstun
echo "      OK"

echo "[5/6] Fixing NAT — UPF-uRLLC..."
docker exec upf-urllc iptables -t nat -F POSTROUTING 2>/dev/null || true
docker exec upf-urllc iptables -t nat -A POSTROUTING \
  -s 10.46.0.0/16 ! -o ogstun -j MASQUERADE
echo "      OK"

echo "[6/6] Fixing TC/QoS — UPF-uRLLC (HTB 20Mbps prio=0)..."
docker exec upf-urllc tc qdisc del dev ogstun root 2>/dev/null || true
docker exec upf-urllc tc qdisc add dev ogstun root handle 1: htb default 10
docker exec upf-urllc tc class add dev ogstun parent 1: classid 1:10 htb \
  rate 20mbit ceil 20mbit burst 1600b prio 0
docker exec upf-urllc tc filter add dev ogstun parent 1: \
  protocol ip prio 1 u32 match ip src 0.0.0.0/0 flowid 1:10
echo "      OK"

# ── VERIFY ──────────────────────────────────────────
echo ""
echo "=================================================="
echo "   VERIFY"
echo "=================================================="

echo ""
echo "--- IP ogstun ---"
echo -n "UPF-eMBB  : "
docker exec upf-embb ip addr show ogstun | grep "inet " | awk '{print $2}'
echo -n "UPF-uRLLC : "
docker exec upf-urllc ip addr show ogstun | grep "inet " | awk '{print $2}'

echo ""
echo "--- TC Rules ---"
echo -n "UPF-eMBB TBF   : "
docker exec upf-embb tc qdisc show dev ogstun | grep -o "tbf.*" || echo "NOT FOUND"
echo -n "UPF-uRLLC HTB  : "
docker exec upf-urllc tc qdisc show dev ogstun | grep -o "htb.*" || echo "NOT FOUND"
echo -n "UPF-uRLLC class: "
docker exec upf-urllc tc class show dev ogstun | grep -o "rate.*ceil.*" || echo "NOT FOUND"

echo ""
echo "--- UE Tunnel IP ---"
echo -n "UE-eMBB  uesimtun0 : "
docker exec ue ip addr show uesimtun0 2>/dev/null \
  | grep "inet " | awk '{print $2}' || echo "TUNNEL DOWN"
echo -n "UE-uRLLC uesimtun0 : "
docker exec ue-urllc ip addr show uesimtun0 2>/dev/null \
  | grep "inet " | awk '{print $2}' || echo "TUNNEL DOWN"

echo ""
echo "=================================================="
echo "   DONE!"
echo "=================================================="
