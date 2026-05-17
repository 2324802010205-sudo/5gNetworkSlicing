#!/bin/bash
PUSHGW="http://localhost:9091"

while true; do
    EMBB_RX=$(docker exec upf-embb cat /proc/net/dev | grep ogstun | awk '{print $2}')
    EMBB_TX=$(docker exec upf-embb cat /proc/net/dev | grep ogstun | awk '{print $10}')
    URLLC_RX=$(docker exec upf-urllc cat /proc/net/dev | grep ogstun | awk '{print $2}')
    URLLC_TX=$(docker exec upf-urllc cat /proc/net/dev | grep ogstun | awk '{print $10}')

    cat << METRICS | curl -s --data-binary @- $PUSHGW/metrics/job/upf_embb
# HELP upf_embb_rx_bytes_total eMBB UPF received bytes on ogstun
# TYPE upf_embb_rx_bytes_total counter
upf_embb_rx_bytes_total $EMBB_RX
# HELP upf_embb_tx_bytes_total eMBB UPF transmitted bytes on ogstun
# TYPE upf_embb_tx_bytes_total counter
upf_embb_tx_bytes_total $EMBB_TX
METRICS

    cat << METRICS | curl -s --data-binary @- $PUSHGW/metrics/job/upf_urllc
# HELP upf_urllc_rx_bytes_total URLLC UPF received bytes on ogstun
# TYPE upf_urllc_rx_bytes_total counter
upf_urllc_rx_bytes_total $URLLC_RX
# HELP upf_urllc_tx_bytes_total URLLC UPF transmitted bytes on ogstun
# TYPE upf_urllc_tx_bytes_total counter
upf_urllc_tx_bytes_total $URLLC_TX
METRICS

    sleep 5
done
