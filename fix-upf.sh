#!/bin/bash
echo "=== Fixing UPF-eMBB ==="
docker exec upf-embb ip addr del 10.45.0.1/16 dev ogstun 2>/dev/null
docker exec upf-embb ip addr add 10.45.0.1/16 dev ogstun
docker exec upf-embb iptables -t nat -A POSTROUTING \
  -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
docker exec upf-embb tc qdisc add dev ogstun root tbf \
  rate 100mbit burst 10mb latency 50ms

echo "=== Fixing UPF-uRLLC ==="
docker exec upf-urllc ip addr del 10.46.0.1/16 dev ogstun 2>/dev/null
docker exec upf-urllc ip addr add 10.46.0.1/16 dev ogstun
docker exec upf-urllc iptables -t nat -A POSTROUTING \
  -s 10.46.0.0/16 ! -o ogstun -j MASQUERADE
docker exec upf-urllc tc qdisc add dev ogstun root handle 1: htb default 10
docker exec upf-urllc tc class add dev ogstun parent 1: classid 1:10 htb \
  rate 20mbit ceil 20mbit burst 1600b prio 0
docker exec upf-urllc tc filter add dev ogstun parent 1: \
  protocol ip prio 1 u32 match ip src 0.0.0.0/0 flowid 1:10

echo "=== Done ==="
docker exec upf-embb ip addr show ogstun | grep inet
docker exec upf-urllc ip addr show ogstun | grep inet
