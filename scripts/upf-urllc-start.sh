#!/bin/bash
set -eo pipefail

# Create ogstun.
if ! grep "ogstun" /proc/net/dev > /dev/null; then
    echo "Creating ogstun device"
    ip tuntap add name ogstun mode tun
fi

ip addr del "$IPV4_TUN_ADDR" dev ogstun 2>/dev/null || true
ip addr add "$IPV4_TUN_ADDR" dev ogstun
sysctl -w net.ipv6.conf.all.disable_ipv6=0
ip addr del "$IPV6_TUN_ADDR" dev ogstun 2>/dev/null || true
ip addr add "$IPV6_TUN_ADDR" dev ogstun
ip link set ogstun up

echo 1 > /proc/sys/net/ipv4/ip_forward
if [ "$ENABLE_NAT" = true ]; then
    iptables -t nat -A POSTROUTING -s "$IPV4_TUN_SUBNET" ! -o ogstun -j MASQUERADE
fi

echo "Applying URLLC QoS rules..."
/bin/bash /scripts/apply-slice-qos.sh urllc ogstun

sleep 10
exec open5gs-upfd -c /opt/open5gs/etc/open5gs/upf-urllc.yaml
