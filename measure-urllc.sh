#!/bin/bash
set -e

echo "=================================================="
echo "   Measure latency and throughput for 2 slices"
echo "=================================================="

UE_EMBB_IP=$(docker exec ue-embb ip addr show uesimtun0 | awk '/inet / {print $2}' | cut -d/ -f1)
UE_URLLC_IP=$(docker exec ue-urllc ip addr show uesimtun0 | awk '/inet / {print $2}' | cut -d/ -f1)

echo ""
echo "UE-eMBB  IP: $UE_EMBB_IP"
echo "UE-uRLLC IP: $UE_URLLC_IP"
echo ""

echo "== Latency eMBB (SST=1) =="
docker exec ue-embb ping -I uesimtun0 1.1.1.1 -c 10
echo ""

echo "== Latency uRLLC (SST=2) =="
docker exec ue-urllc ping -I uesimtun0 1.1.1.1 -c 10
echo ""

echo "== Throughput eMBB =="
docker exec ue-embb iperf3 -c 172.20.0.100 -t 20 -P 4 -B "$UE_EMBB_IP" -R
echo ""

echo "== Throughput uRLLC =="
docker exec ue-urllc iperf3 -c 172.20.0.101 -t 20 -P 4 -B "$UE_URLLC_IP" -R
echo ""

echo "DONE"
