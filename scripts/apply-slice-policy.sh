#!/bin/bash
set -euo pipefail

# tc/htb/netem/fq_codel is used only as a testbed proxy for resource pressure
# and policy enforcement, not as standard 5G QoS.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CAPACITY_FILE="reports/capacity.env"
CAPACITY_SOURCE="fallback defaults"
DYNAMIC_NORMAL_EMBB_MBPS=12
DYNAMIC_NORMAL_URLLC_MBPS=3
DYNAMIC_PRIORITY_EMBB_MBPS=10
DYNAMIC_PRIORITY_URLLC_MBPS=5

is_positive_number() {
    awk -v value="$1" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}'
}

load_capacity() {
    if [ ! -f "$CAPACITY_FILE" ]; then
        return
    fi

    unset DYNAMIC_NORMAL_EMBB_MBPS DYNAMIC_NORMAL_URLLC_MBPS
    unset DYNAMIC_PRIORITY_EMBB_MBPS DYNAMIC_PRIORITY_URLLC_MBPS
    # shellcheck disable=SC1090
    source "$CAPACITY_FILE"
    if is_positive_number "${DYNAMIC_NORMAL_EMBB_MBPS:-}" &&
        is_positive_number "${DYNAMIC_NORMAL_URLLC_MBPS:-}" &&
        is_positive_number "${DYNAMIC_PRIORITY_EMBB_MBPS:-}" &&
        is_positive_number "${DYNAMIC_PRIORITY_URLLC_MBPS:-}"; then
        CAPACITY_SOURCE="$CAPACITY_FILE"
    else
        echo "WARNING: Invalid values in $CAPACITY_FILE; using fallback defaults." >&2
        DYNAMIC_NORMAL_EMBB_MBPS=12
        DYNAMIC_NORMAL_URLLC_MBPS=3
        DYNAMIC_PRIORITY_EMBB_MBPS=10
        DYNAMIC_PRIORITY_URLLC_MBPS=5
    fi
}

load_capacity
echo "Capacity source: $CAPACITY_SOURCE"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/apply-slice-policy.sh --profile no-policy
  bash scripts/apply-slice-policy.sh --profile static
  bash scripts/apply-slice-policy.sh --profile dynamic-normal
  bash scripts/apply-slice-policy.sh --profile dynamic-urllc-priority
  bash scripts/apply-slice-policy.sh --profile fault-urllc-congestion
EOF
}

PROFILE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            PROFILE="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$PROFILE" ]; then
    echo "Missing required --profile" >&2
    usage >&2
    exit 2
fi

need_container() {
    local name="$1"
    local state

    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running" >&2
        exit 1
    fi
}

clear_qdisc() {
    local container="$1"

    docker exec "$container" sh -c 'tc qdisc del dev ogstun root 2>/dev/null || true'
}

reset_qdisc() {
    clear_qdisc "$1"
}

apply_htb_fq_codel() {
    local container="$1"
    local rate="$2"

    reset_qdisc "$container"
    docker exec "$container" sh -c "
tc qdisc add dev ogstun root handle 1: htb default 10
tc class add dev ogstun parent 1: classid 1:10 htb rate $rate ceil $rate
tc qdisc add dev ogstun parent 1:10 handle 10: fq_codel
"
}

apply_htb_netem_fq_codel() {
    local container="$1"
    local rate="$2"
    local netem_args="$3"

    reset_qdisc "$container"
    docker exec "$container" sh -c "
tc qdisc add dev ogstun root handle 1: htb default 10
tc class add dev ogstun parent 1: classid 1:10 htb rate $rate ceil $rate
tc qdisc add dev ogstun parent 1:10 handle 10: netem $netem_args
tc qdisc add dev ogstun parent 10:1 handle 100: fq_codel
"
}

show_policy() {
    local container="$1"

    echo
    echo "$container qdisc:"
    docker exec "$container" tc qdisc show dev ogstun
    echo "$container class:"
    docker exec "$container" tc class show dev ogstun
}

need_container upf-embb
need_container upf-urllc

case "$PROFILE" in
    no-policy)
        clear_qdisc upf-embb
        clear_qdisc upf-urllc
        echo "Applied profile=no-policy"
        ;;
    static|dynamic-normal)
        apply_htb_fq_codel upf-embb "${DYNAMIC_NORMAL_EMBB_MBPS}Mbit"
        apply_htb_fq_codel upf-urllc "${DYNAMIC_NORMAL_URLLC_MBPS}Mbit"
        echo "Applied profile=$PROFILE embb=${DYNAMIC_NORMAL_EMBB_MBPS}Mbit urllc=${DYNAMIC_NORMAL_URLLC_MBPS}Mbit"
        ;;
    dynamic-urllc-priority)
        apply_htb_fq_codel upf-embb "${DYNAMIC_PRIORITY_EMBB_MBPS}Mbit"
        apply_htb_fq_codel upf-urllc "${DYNAMIC_PRIORITY_URLLC_MBPS}Mbit"
        echo "Applied profile=dynamic-urllc-priority embb=${DYNAMIC_PRIORITY_EMBB_MBPS}Mbit urllc=${DYNAMIC_PRIORITY_URLLC_MBPS}Mbit"
        ;;
    fault-urllc-congestion)
        apply_htb_netem_fq_codel upf-embb "${DYNAMIC_NORMAL_EMBB_MBPS}Mbit" "delay 6ms 1ms"
        apply_htb_netem_fq_codel upf-urllc 1Mbit "delay 50ms 5ms loss 1%"
        echo "Applied profile=fault-urllc-congestion embb=${DYNAMIC_NORMAL_EMBB_MBPS}Mbit urllc=1Mbit with URLLC delay/loss fault"
        ;;
    *)
        echo "Unsupported profile: $PROFILE" >&2
        usage >&2
        exit 2
        ;;
esac

show_policy upf-embb
show_policy upf-urllc
