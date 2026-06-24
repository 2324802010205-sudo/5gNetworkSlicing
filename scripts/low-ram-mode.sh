#!/bin/bash
set -euo pipefail

STOP_MONITORING=false

usage() {
    cat <<'EOF'
Usage:
  bash scripts/low-ram-mode.sh
  bash scripts/low-ram-mode.sh --stop-monitoring

Always stops optional heavy containers: cadvisor, node-exporter, webui.
Use --stop-monitoring to also stop prometheus, pushgateway, and grafana.
Core 5G containers are never stopped.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --stop-monitoring)
            STOP_MONITORING=true
            shift
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

stop_if_present() {
    local name="$1"
    local state

    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    case "$state" in
        running|restarting|paused)
            echo "Stopping optional container: $name"
            docker stop "$name" >/dev/null
            ;;
        "")
            echo "Optional container not present: $name"
            ;;
        *)
            echo "Optional container already stopped: $name ($state)"
            ;;
    esac
}

for container in cadvisor node-exporter webui; do
    stop_if_present "$container"
done

if [ "$STOP_MONITORING" = true ]; then
    for container in prometheus pushgateway grafana; do
        stop_if_present "$container"
    done
else
    echo "Monitoring containers left unchanged. Use --stop-monitoring to stop them."
fi

echo "Low-RAM mode complete. Core 5G containers were not touched."
