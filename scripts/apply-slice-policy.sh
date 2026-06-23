#!/bin/bash
set -euo pipefail

# tc/htb/netem/fq_codel is used only as a testbed proxy for resource pressure
# and policy enforcement, not as standard 5G QoS.

usage() {
    cat <<'EOF'
Usage:
  bash scripts/apply-slice-policy.sh --profile no-policy
  bash scripts/apply-slice-policy.sh --profile static
  bash scripts/apply-slice-policy.sh --profile dynamic-normal
  bash scripts/apply-slice-policy.sh --profile dynamic-urllc-priority
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

apply_htb_limit() {
    local container="$1"
    local rate="$2"

    docker exec "$container" sh -c "
tc qdisc replace dev ogstun root handle 1: htb default 10
tc class replace dev ogstun parent 1: classid 1:10 htb rate $rate ceil $rate
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
        apply_htb_limit upf-embb 12Mbit
        apply_htb_limit upf-urllc 3Mbit
        echo "Applied profile=$PROFILE embb=12Mbit urllc=3Mbit"
        ;;
    dynamic-urllc-priority)
        apply_htb_limit upf-embb 10Mbit
        apply_htb_limit upf-urllc 5Mbit
        echo "Applied profile=dynamic-urllc-priority embb=10Mbit urllc=5Mbit"
        ;;
    *)
        echo "Unsupported profile: $PROFILE" >&2
        usage >&2
        exit 2
        ;;
esac

show_policy upf-embb
show_policy upf-urllc
