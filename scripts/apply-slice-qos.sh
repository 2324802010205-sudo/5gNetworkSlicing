#!/bin/bash
set -euo pipefail

# tc/htb/netem/fq_codel is used only as a testbed proxy for resource pressure
# and policy enforcement, not as standard 5G QoS.

SLICE="${1:-}"
DEV="${2:-ogstun}"
EMBB_RATE="${EMBB_RATE:-2mbit}"
EMBB_CEIL="${EMBB_CEIL:-6mbit}"
EMBB_BURST="${EMBB_BURST:-128k}"
EMBB_CBURST="${EMBB_CBURST:-128k}"
EMBB_DELAY="${EMBB_DELAY:-6ms}"
EMBB_JITTER="${EMBB_JITTER:-1ms}"
EMBB_LOSS="${EMBB_LOSS:-0%}"
EMBB_LIMIT="${EMBB_LIMIT:-256}"
EMBB_FQ_CODEL_LIMIT="${EMBB_FQ_CODEL_LIMIT:-512}"
EMBB_FQ_CODEL_TARGET="${EMBB_FQ_CODEL_TARGET:-5ms}"
EMBB_FQ_CODEL_INTERVAL="${EMBB_FQ_CODEL_INTERVAL:-100ms}"
URLLC_RATE="${URLLC_RATE:-3mbit}"
URLLC_CEIL="${URLLC_CEIL:-7mbit}"
URLLC_BURST="${URLLC_BURST:-32k}"
URLLC_CBURST="${URLLC_CBURST:-32k}"
URLLC_DELAY="${URLLC_DELAY:-1ms}"
URLLC_JITTER="${URLLC_JITTER:-0.1ms}"
URLLC_LOSS="${URLLC_LOSS:-0.01%}"
URLLC_LIMIT="${URLLC_LIMIT:-8}"
URLLC_FQ_CODEL_LIMIT="${URLLC_FQ_CODEL_LIMIT:-32}"
URLLC_FQ_CODEL_TARGET="${URLLC_FQ_CODEL_TARGET:-1ms}"
URLLC_FQ_CODEL_INTERVAL="${URLLC_FQ_CODEL_INTERVAL:-5ms}"

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
        tc qdisc add dev "$DEV" root handle 1: htb default 10 r2q 10
        tc class add dev "$DEV" parent 1: classid 1:10 htb \
            rate "$EMBB_RATE" ceil "$EMBB_CEIL" \
            burst "$EMBB_BURST" cburst "$EMBB_CBURST" prio 2
        tc qdisc add dev "$DEV" parent 1:10 handle 10: netem \
            delay "$EMBB_DELAY" "$EMBB_JITTER" distribution normal \
            loss "$EMBB_LOSS" limit "$EMBB_LIMIT"
        tc qdisc add dev "$DEV" parent 10:1 handle 20: fq_codel \
            limit "$EMBB_FQ_CODEL_LIMIT" target "$EMBB_FQ_CODEL_TARGET" \
            interval "$EMBB_FQ_CODEL_INTERVAL" quantum 1514 ecn
        ;;
    urllc)
        # URLLC trades peak throughput for low delay, low jitter, and smaller
        # queues so latency does not grow too much under short bursts. netem
        # models radio delay; fq_codel keeps the remaining queue short.
        tc qdisc add dev "$DEV" root handle 1: htb default 10 r2q 10
        tc class add dev "$DEV" parent 1: classid 1:10 htb \
            rate "$URLLC_RATE" ceil "$URLLC_CEIL" \
            burst "$URLLC_BURST" cburst "$URLLC_CBURST" prio 0
        tc qdisc add dev "$DEV" parent 1:10 handle 10: netem \
            delay "$URLLC_DELAY" "$URLLC_JITTER" distribution normal \
            loss "$URLLC_LOSS" limit "$URLLC_LIMIT"
        tc qdisc add dev "$DEV" parent 10:1 handle 20: fq_codel \
            limit "$URLLC_FQ_CODEL_LIMIT" target "$URLLC_FQ_CODEL_TARGET" \
            interval "$URLLC_FQ_CODEL_INTERVAL" quantum 300 ecn
        ;;
    *)
        usage
        ;;
esac

echo "Applied $SLICE QoS on $DEV"
tc qdisc show dev "$DEV"
