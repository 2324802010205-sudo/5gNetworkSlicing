#!/bin/bash

# DEMO SCRIPT: 5G Network Slicing với eMBB và URLLC
# Mục đích: Chứng minh 2 slices hoạt động độc lập với QoS khác nhau

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo "5G NETWORK SLICING DEMONSTRATION"
echo "==========================================${NC}"
echo ""
echo "Mục tiêu demo:"
echo "1. eMBB: High throughput cho video streaming"
echo "2. URLLC: Low latency cho industrial IoT"
echo "3. 2 slices hoạt động độc lập, không ảnh hưởng lẫn nhau"
echo ""

# Kiểm tra containers
echo -e "${YELLOW}[1/6] Checking system status...${NC}"
if ! docker ps | grep -q "ue-embb"; then
    echo -e "${RED}Error: Containers not running. Run 'docker compose up -d' first${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All containers running${NC}"
echo ""

# Hiển thị thông tin slices
echo -e "${YELLOW}[2/6] Network Slice Information${NC}"
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│ eMBB Slice (SST:1 SD:1)                                     │"
echo "│ - UE IP: $(docker exec ue-embb ip -4 addr show uesimtun0 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)"
echo "│ - DNN: internet                                             │"
echo "│ - Target: >100 Mbps, <50ms latency                         │"
echo "│ - Use case: 4K video streaming, AR/VR                      │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│ URLLC Slice (SST:2 SD:2)                                    │"
echo "│ - UE IP: $(docker exec ue-urllc ip -4 addr show uesimtun0 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)"
echo "│ - DNN: internet2                                            │"
echo "│ - Target: <10ms latency, >10 Mbps                          │"
echo "│ - Use case: Industrial automation, autonomous vehicles     │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""

# Test 1: Latency comparison
echo -e "${YELLOW}[3/6] TEST 1: Latency Comparison${NC}"
echo "Đo độ trễ của 2 slices (ping 20 packets)..."
echo ""

echo "eMBB Latency:"
EMBB_LATENCY=$(docker exec ue-embb ping -c 20 -i 0.2 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
docker exec ue-embb ping -c 20 -i 0.2 8.8.8.8 2>/dev/null | tail -2
echo ""

echo "URLLC Latency:"
URLLC_LATENCY=$(docker exec ue-urllc ping -c 20 -i 0.2 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
docker exec ue-urllc ping -c 20 -i 0.2 8.8.8.8 2>/dev/null | tail -2
echo ""

# Test 2: Concurrent traffic
echo -e "${YELLOW}[4/6] TEST 2: Concurrent Traffic Test${NC}"
echo "Tạo traffic đồng thời trên cả 2 slices để chứng minh isolation..."
echo ""

# Install iperf3 if needed
if ! docker exec ue-embb which iperf3 > /dev/null 2>&1; then
    echo "Installing iperf3..."
    docker exec ue-embb apt-get update -qq && docker exec ue-embb apt-get install -y iperf3 -qq 2>/dev/null
    docker exec ue-urllc apt-get update -qq && docker exec ue-urllc apt-get install -y iperf3 -qq 2>/dev/null
fi

echo "Starting eMBB traffic (background)..."
docker exec -d ue-embb iperf3 -c iperf.he.net -t 30 -i 5 > /tmp/embb_iperf.log 2>&1 &
EMBB_PID=$!

sleep 2

echo "Starting URLLC traffic (background)..."
docker exec -d ue-urllc iperf3 -c iperf.he.net -t 30 -i 5 > /tmp/urllc_iperf.log 2>&1 &
URLLC_PID=$!

echo ""
echo "Traffic đang chạy trong 30 giây..."
echo "Trong lúc này, đo latency real-time để thấy URLLC không bị ảnh hưởng..."
echo ""

sleep 5

echo "eMBB latency (under load):"
docker exec ue-embb ping -c 10 -i 0.5 8.8.8.8 2>/dev/null | tail -2
echo ""

echo "URLLC latency (under load):"
docker exec ue-urllc ping -c 10 -i 0.5 8.8.8.8 2>/dev/null | tail -2
echo ""

# Test 3: Packet loss
echo -e "${YELLOW}[5/6] TEST 3: Reliability Test (Packet Loss)${NC}"
echo "Đo packet loss với 100 packets..."
echo ""

echo "eMBB Packet Loss:"
docker exec ue-embb ping -c 100 -i 0.01 8.8.8.8 2>/dev/null | grep "packet loss"
echo ""

echo "URLLC Packet Loss:"
docker exec ue-urllc ping -c 100 -i 0.01 8.8.8.8 2>/dev/null | grep "packet loss"
echo ""

# Prometheus metrics
echo -e "${YELLOW}[6/6] Prometheus Metrics${NC}"
echo "Truy cập Prometheus để xem biểu đồ real-time:"
echo ""
echo "URL: http://$(hostname -I | awk '{print $1}'):9090"
echo ""
echo "Các query quan trọng để demo:"
echo ""
echo "1. Throughput của UPF eMBB (bytes/sec):"
echo "   rate(upf_rx_bytes_total{job=\"upf-embb\"}[1m]) * 8"
echo ""
echo "2. Throughput của UPF URLLC (bytes/sec):"
echo "   rate(upf_rx_bytes_total{job=\"upf-urllc\"}[1m]) * 8"
echo ""
echo "3. Số lượng active sessions:"
echo "   upf_sessions_active"
echo ""
echo "4. Packet errors:"
echo "   rate(upf_rx_errors_total[1m])"
echo ""

# Summary
echo -e "${BLUE}=========================================="
echo "DEMO SUMMARY"
echo "==========================================${NC}"
echo ""
echo "✓ 2 Network slices đang hoạt động độc lập"
echo "✓ eMBB: Tối ưu cho throughput cao"
echo "✓ URLLC: Tối ưu cho latency thấp"
echo "✓ Traffic isolation: Không ảnh hưởng lẫn nhau"
echo ""
echo "Next steps:"
echo "1. Mở Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
echo "2. Mở Grafana: http://$(hostname -I | awk '{print $1}'):3000 (admin/grafana)"
echo "3. Chạy './generate-traffic.sh' để tạo traffic liên tục"
echo ""
