#!/bin/bash
clear
echo "╔══════════════════════════════════════════════════════╗"
echo "║   📊 KB1-KB4: Đo Latency + Throughput 2 Slice       ║"
echo "╚══════════════════════════════════════════════════════╝"

# Lấy IP tự động
UE_EMBB_IP=$(docker exec ue ip addr show uesimtun0 \
  | grep "inet " | awk '{print $2}' | cut -d/ -f1)
UE_URLLC_IP=$(docker exec ue-urllc ip addr show uesimtun0 \
  | grep "inet " | awk '{print $2}' | cut -d/ -f1)

echo ""
echo "  UE-eMBB  IP: $UE_EMBB_IP"
echo "  UE-uRLLC IP: $UE_URLLC_IP"
echo ""

# ── KB1: Latency eMBB ───────────────────────────────────
echo "══════════════════════════════════════"
echo "  KB1: Latency eMBB (SST=1)"
echo "══════════════════════════════════════"
docker exec ue ping -I uesimtun0 1.1.1.1 -c 10
echo ""

# ── KB2: Latency uRLLC ──────────────────────────────────
echo "══════════════════════════════════════"
echo "  KB2: Latency uRLLC (SST=2)"
echo "══════════════════════════════════════"
docker exec ue-urllc ping -I uesimtun0 1.1.1.1 -c 10
echo ""

# ── Start iperf3-server ──────────────────────────────────
docker start iperf3-server > /dev/null 2>&1
sleep 2

# ── KB3: Throughput eMBB ────────────────────────────────
echo "══════════════════════════════════════"
echo "  KB3: Throughput eMBB — TBF 100Mbps"
echo "══════════════════════════════════════"
docker exec ue iperf3 -c 172.20.0.100 -t 20 -P 4 -B $UE_EMBB_IP -R
echo ""

# ── KB4: Throughput uRLLC ───────────────────────────────
echo "══════════════════════════════════════"
echo "  KB4: Throughput uRLLC — HTB 20Mbps"
echo "══════════════════════════════════════"
docker exec ue-urllc iperf3 -c 172.20.0.100 -t 20 -P 4 -B $UE_URLLC_IP -R
echo ""

# ── Tóm tắt kết quả ────────────────────────────────────
echo "══════════════════════════════════════"
echo "  📋 TÓM TẮT KẾT QUẢ"
echo "══════════════════════════════════════"
echo ""
echo "  [KB1] eMBB  Latency : xem rtt avg bên trên"
echo "  [KB2] uRLLC Latency : xem rtt avg bên trên"
echo "  [KB3] eMBB  Throughput: xem SUM receiver"
echo "         → Kỳ vọng: không vượt 100Mbps (TBF)"
echo "  [KB4] uRLLC Throughput: xem SUM receiver"
echo "         → Kỳ vọng: ~18-20Mbps (HTB cứng)"
echo ""
echo "  DONE!"
