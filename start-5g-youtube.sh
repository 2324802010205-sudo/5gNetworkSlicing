#!/bin/bash
set -e

echo "=================================================="
echo "   5G YouTube Setup Script"
echo "   Open5GS + UERANSIM + microsocks SOCKS5 Proxy"
echo "=================================================="

# ── BƯỚC 1: Fix UPF ─────────────────────────────────
echo ""
echo "[1/7] Fixing UPF IP/NAT/QoS..."
bash ~/5g-lab/fix-upf.sh > /dev/null 2>&1
echo "      OK"

# ── BƯỚC 2: Lấy UE PID ──────────────────────────────
echo "[2/7] Getting UE namespace PID..."
UE_PID=$(docker inspect --format '{{.State.Pid}}' ue)
echo "      UE PID: $UE_PID"

# ── BƯỚC 3: Tạo veth pair ───────────────────────────
echo "[3/7] Creating veth pair (host ↔ UE namespace)..."
sudo ip link del veth-host 2>/dev/null || true
sudo ip link add veth-host type veth peer name veth-ue
sudo ip link set veth-ue netns $UE_PID
sudo ip addr add 192.168.100.1/24 dev veth-host
sudo ip link set veth-host up
sudo nsenter -t $UE_PID -n -- ip addr add 192.168.100.2/24 dev veth-ue 2>/dev/null || true
sudo nsenter -t $UE_PID -n -- ip link set veth-ue up
echo "      OK — veth-host: 192.168.100.1 | veth-ue: 192.168.100.2"

# ── BƯỚC 4: Fix route trong UE namespace ────────────
echo "[4/7] Fixing route in UE namespace (default via uesimtun0)..."
sudo nsenter -t $UE_PID -n -- ip route del default 2>/dev/null || true
sudo nsenter -t $UE_PID -n -- ip route add default dev uesimtun0
sudo nsenter -t $UE_PID -n -- iptables -t nat -F 2>/dev/null || true
sudo nsenter -t $UE_PID -n -- iptables -t nat -A POSTROUTING -j MASQUERADE
sudo nsenter -t $UE_PID -n -- iptables -A FORWARD -j ACCEPT 2>/dev/null || true
echo "      OK — traffic sẽ đi qua uesimtun0 → 5G Core"

# ── BƯỚC 5: Fix DNS ──────────────────────────────────
echo "[5/7] Setting DNS in UE namespace..."
sudo nsenter -t $UE_PID -n -- bash -c "echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
echo "      OK — DNS: 1.1.1.1 (Cloudflare)"

# ── BƯỚC 6: Start microsocks ─────────────────────────
echo "[6/7] Starting microsocks SOCKS5 proxy..."
sudo pkill microsocks 2>/dev/null || true
sleep 1
sudo nsenter -t $UE_PID -n -- microsocks -i 0.0.0.0 -p 1080 &
PROXY_PID=$!
sleep 2
echo "      OK — SOCKS5 proxy PID: $PROXY_PID"

# ── BƯỚC 7: Verify ──────────────────────────────────
echo ""
echo "[7/7] Verifying..."

# Check proxy listening
PROXY_CHECK=$(sudo nsenter -t $UE_PID -n -- ss -tlnp 2>/dev/null | grep 1080 | wc -l)
if [ "$PROXY_CHECK" -gt "0" ]; then
  echo "      ✅ microsocks đang listen tại 0.0.0.0:1080"
else
  echo "      ❌ microsocks CHƯA chạy — thử lại!"
  exit 1
fi

# Check tunnel
UE_IP=$(docker exec ue ip addr show uesimtun0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
echo "      ✅ UE tunnel IP: $UE_IP"

# Quick ping test
PING_RESULT=$(sudo nsenter -t $UE_PID -n -- ping -I uesimtun0 1.1.1.1 -c 2 -W 3 2>/dev/null | grep "0% packet loss" | wc -l)
if [ "$PING_RESULT" -gt "0" ]; then
  echo "      ✅ Internet qua 5G: OK (ping 1.1.1.1 0% loss)"
else
  echo "      ⚠️  Ping 1.1.1.1 không được — check lại tunnel"
fi

echo ""
echo "=================================================="
echo "   DONE! Cấu hình Firefox để vào YouTube qua 5G"
echo "=================================================="
echo ""
echo "   Firefox → Settings → Network Settings:"
echo "   ┌─────────────────────────────────────┐"
echo "   │ SOCKS Host: 192.168.100.2           │"
echo "   │ Port:       1080                    │"
echo "   │ SOCKS v5    ✅                      │"
echo "   │ Proxy DNS   ✅                      │"
echo "   └─────────────────────────────────────┘"
echo ""
echo "   Sau đó mở Firefox → youtube.com → 🎉"
echo ""
echo "   Xem traffic qua 5G:"
echo "   docker exec upf-embb tcpdump -i ogstun -n 2>/dev/null"
echo ""
echo "=================================================="
