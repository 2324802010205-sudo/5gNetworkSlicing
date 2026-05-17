#!/bin/bash
set -euo pipefail

SLICE="${1:-}"
DEV="${2:-ogstun}"

usage() {
    echo "Usage: $0 <embb|urllc> [device]" >&2
    exit 2
}

[ -n "$SLICE" ] || usage

tc qdisc del dev "$DEV" root 2>/dev/null || true

case "$SLICE" in
    embb)
        # eMBB favors large sustained throughput. The added delay/jitter keeps
        # the lab closer to a loaded mobile broadband path than a LAN link.
        tc qdisc add dev "$DEV" root handle 1: htb default 10 r2q 1000
        tc class add dev "$DEV" parent 1: classid 1:10 htb \
            rate 150mbit ceil 180mbit burst 256k cburst 256k prio 2
        tc qdisc add dev "$DEV" parent 1:10 handle 10: netem \
            delay 18ms 6ms distribution normal loss 0.05% limit 2000
        ;;
    urllc)
        # URLLC trades peak throughput for low delay, low jitter, and smaller
        # queues so latency does not grow too much under short bursts. netem
        # models radio delay; fq_codel keeps the remaining queue short.
        tc qdisc add dev "$DEV" root handle 1: htb default 10 r2q 1000
        tc class add dev "$DEV" parent 1: classid 1:10 htb \
            rate 20mbit ceil 25mbit burst 32k cburst 32k prio 0
        tc qdisc add dev "$DEV" parent 1:10 handle 10: netem \
            delay 2ms 0.3ms distribution normal loss 0.01% limit 20
        tc qdisc add dev "$DEV" parent 10:1 handle 20: fq_codel \
            limit 64 target 1ms interval 10ms quantum 300 ecn
        ;;
    *)
        usage
        ;;
esac

echo "Applied $SLICE QoS on $DEV"
tc qdisc show dev "$DEV"
