#!/bin/bash

# Script tạo traffic liên tục để demo trên Prometheus/Grafana

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo "5G TRAFFIC GENERATOR"
echo "==========================================${NC}"
echo ""
echo "Script này sẽ tạo traffic liên tục để bạn có thể:"
echo "- Xem biểu đồ real-time trên Prometheus/Grafana"
echo "- Demo sự khác biệt giữa eMBB và URLLC"
echo "- Chứng minh network slicing isolation"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Install tools
if ! docker exec ue-embb which iperf3 > /dev/null 2>&1; then
    echo "Installing tools..."
    docker exec ue-embb apt-get update -qq && docker exec ue-embb apt-get install -y iperf3 curl -qq
    docker exec ue-urllc apt-get update -qq && docker exec ue-urllc apt-get install -y iperf3 curl -qq
fi

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping traffic generators...${NC}"
    docker exec ue-embb pkill -f iperf3 2>/dev/null || true
    docker exec ue-urllc pkill -f iperf3 2>/dev/null || true
    docker exec ue-embb pkill -f ping 2>/dev/null || true
    docker exec ue-urllc pkill -f ping 2>/dev/null || true
    echo -e "${GREEN}Done!${NC}"
    exit 0
}

trap cleanup INT TERM

echo -e "${GREEN}Starting traffic generators...${NC}"
echo ""

# eMBB: High throughput traffic (simulating video streaming)
echo "eMBB: Simulating 4K video streaming (high bandwidth)..."
docker exec -d ue-embb sh -c 'while true; do iperf3 -c iperf.he.net -t 60 -i 10; sleep 5; done' > /dev/null 2>&1

# URLLC: Low latency traffic (simulating IoT sensors)
echo "URLLC: Simulating industrial IoT sensors (low latency)..."
docker exec -d ue-urllc sh -c 'while true; do ping -i 0.1 8.8.8.8 > /dev/null 2>&1; done' > /dev/null 2>&1

# Additional HTTP traffic
echo "eMBB: Adding HTTP download traffic..."
docker exec -d ue-embb sh -c 'while true; do curl -s http://speedtest.tele2.net/10MB.zip > /dev/null; sleep 10; done' > /dev/null 2>&1

echo ""
echo -e "${GREEN}✓ Traffic generators started!${NC}"
echo ""
echo "Giờ bạn có thể:"
echo "1. Mở Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
echo "2. Mở Grafana: http://$(hostname -I | awk '{print $1}'):3000"
echo "3. Xem metrics real-time"
echo ""
echo "Monitoring traffic..."
echo ""

# Monitor loop
while true; do
    clear
    echo -e "${BLUE}=========================================="
    echo "REAL-TIME TRAFFIC MONITORING"
    echo "==========================================${NC}"
    echo ""
    date
    echo ""
    
    echo -e "${YELLOW}eMBB Slice (High Throughput):${NC}"
    echo "Interface: uesimtun0"
    docker exec ue-embb cat /proc/net/dev | grep uesimtun0 | awk '{printf "  RX: %d bytes, TX: %d bytes\n", $2, $10}'
    echo ""
    
    echo -e "${YELLOW}URLLC Slice (Low Latency):${NC}"
    echo "Interface: uesimtun0"
    docker exec ue-urllc cat /proc/net/dev | grep uesimtun0 | awk '{printf "  RX: %d bytes, TX: %d bytes\n", $2, $10}'
    echo ""
    
    echo "Press Ctrl+C to stop..."
    sleep 5
done
