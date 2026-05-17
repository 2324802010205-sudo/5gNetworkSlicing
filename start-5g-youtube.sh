#!/bin/bash
set -e

echo "=================================================="
echo "   5G YouTube Setup"
echo "   Open5GS + UERANSIM + microsocks SOCKS5 Proxy"
echo "=================================================="

echo ""
echo "[1/7] Fixing UPF IP/NAT/QoS..."
bash ./fix-upf.sh >/dev/null 2>&1
echo "      OK"

echo "[2/7] Getting UE namespace PID..."
UE_PID=$(docker inspect --format '{{.State.Pid}}' ue-embb)
echo "      UE PID: $UE_PID"

echo "[3/7] Creating veth pair..."
sudo ip link del veth-host 2>/dev/null || true
sudo ip link add veth-host type veth peer name veth-ue
sudo ip link set veth-ue netns "$UE_PID"
sudo ip addr add 192.168.100.1/24 dev veth-host
sudo ip link set veth-host up
sudo nsenter -t "$UE_PID" -n -- ip addr add 192.168.100.2/24 dev veth-ue 2>/dev/null || true
sudo nsenter -t "$UE_PID" -n -- ip link set veth-ue up
echo "      OK - veth-host: 192.168.100.1, veth-ue: 192.168.100.2"

echo "[4/7] Routing UE namespace through uesimtun0..."
sudo nsenter -t "$UE_PID" -n -- ip route del default 2>/dev/null || true
sudo nsenter -t "$UE_PID" -n -- ip route add default dev uesimtun0
sudo nsenter -t "$UE_PID" -n -- iptables -t nat -F 2>/dev/null || true
sudo nsenter -t "$UE_PID" -n -- iptables -t nat -A POSTROUTING -j MASQUERADE
sudo nsenter -t "$UE_PID" -n -- iptables -A FORWARD -j ACCEPT 2>/dev/null || true
echo "      OK"

echo "[5/7] Setting DNS in UE namespace..."
sudo nsenter -t "$UE_PID" -n -- bash -c "echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
echo "      OK"

echo "[6/7] Starting microsocks SOCKS5 proxy..."
sudo pkill microsocks 2>/dev/null || true
sleep 1
sudo nsenter -t "$UE_PID" -n -- microsocks -i 0.0.0.0 -p 1080 &
PROXY_PID=$!
sleep 2
echo "      OK - SOCKS5 proxy PID: $PROXY_PID"

echo ""
echo "[7/7] Verifying..."
PROXY_CHECK=$(sudo nsenter -t "$UE_PID" -n -- ss -tlnp 2>/dev/null | grep 1080 | wc -l)
if [ "$PROXY_CHECK" -gt "0" ]; then
  echo "      OK - microsocks listening on 0.0.0.0:1080"
else
  echo "      FAIL - microsocks is not running"
  exit 1
fi

UE_IP=$(docker exec ue-embb ip addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
echo "      OK - UE tunnel IP: $UE_IP"

echo ""
echo "Configure Firefox SOCKS5 proxy:"
echo "  Host: 192.168.100.2"
echo "  Port: 1080"
echo "  Proxy DNS: enabled"
echo ""
echo "DONE"
