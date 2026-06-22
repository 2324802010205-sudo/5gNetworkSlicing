#!/bin/bash
set -eu

PUSHGW="${PUSHGW:-http://localhost:9091}"
INTERVAL="${INTERVAL:-15}"

while true; do
    EMBB_RX=$(docker exec upf-embb awk '$1 ~ /ogstun:/ {print $2}' /proc/net/dev)
    EMBB_TX=$(docker exec upf-embb awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev)
    URLLC_RX=$(docker exec upf-urllc awk '$1 ~ /ogstun:/ {print $2}' /proc/net/dev)
    URLLC_TX=$(docker exec upf-urllc awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev)

    printf '%s\n' \
      '# HELP upf_embb_rx_bytes_total eMBB UPF received bytes on ogstun' \
      '# TYPE upf_embb_rx_bytes_total counter' \
      "upf_embb_rx_bytes_total ${EMBB_RX:-0}" \
      '# HELP upf_embb_tx_bytes_total eMBB UPF transmitted bytes on ogstun' \
      '# TYPE upf_embb_tx_bytes_total counter' \
      "upf_embb_tx_bytes_total ${EMBB_TX:-0}" \
      '# HELP upf_ogstun_rx_bytes_total UPF received bytes on ogstun' \
      '# TYPE upf_ogstun_rx_bytes_total counter' \
      "upf_ogstun_rx_bytes_total{slice=\"embb\",upf=\"upf-embb\"} ${EMBB_RX:-0}" \
      '# HELP upf_ogstun_tx_bytes_total UPF transmitted bytes on ogstun' \
      '# TYPE upf_ogstun_tx_bytes_total counter' \
      "upf_ogstun_tx_bytes_total{slice=\"embb\",upf=\"upf-embb\"} ${EMBB_TX:-0}" \
      | curl -fsS --data-binary @- "$PUSHGW/metrics/job/upf-embb" >/dev/null

    printf '%s\n' \
      '# HELP upf_urllc_rx_bytes_total URLLC UPF received bytes on ogstun' \
      '# TYPE upf_urllc_rx_bytes_total counter' \
      "upf_urllc_rx_bytes_total ${URLLC_RX:-0}" \
      '# HELP upf_urllc_tx_bytes_total URLLC UPF transmitted bytes on ogstun' \
      '# TYPE upf_urllc_tx_bytes_total counter' \
      "upf_urllc_tx_bytes_total ${URLLC_TX:-0}" \
      '# HELP upf_ogstun_rx_bytes_total UPF received bytes on ogstun' \
      '# TYPE upf_ogstun_rx_bytes_total counter' \
      "upf_ogstun_rx_bytes_total{slice=\"urllc\",upf=\"upf-urllc\"} ${URLLC_RX:-0}" \
      '# HELP upf_ogstun_tx_bytes_total UPF transmitted bytes on ogstun' \
      '# TYPE upf_ogstun_tx_bytes_total counter' \
      "upf_ogstun_tx_bytes_total{slice=\"urllc\",upf=\"upf-urllc\"} ${URLLC_TX:-0}" \
      | curl -fsS --data-binary @- "$PUSHGW/metrics/job/upf-urllc" >/dev/null

    sleep "$INTERVAL"
done
