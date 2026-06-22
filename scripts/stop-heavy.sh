#!/bin/bash
set -u

docker compose stop \
    prometheus \
    grafana \
    pushgateway \
    cadvisor \
    node-exporter \
    webui \
    embb-iperf-server \
    urllc-iperf-server \
    mqtt-server \
    >/dev/null 2>&1 || true

echo "Stopped optional/heavy services if they were running."
