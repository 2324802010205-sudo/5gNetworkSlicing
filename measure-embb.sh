#!/bin/bash
clear
echo "╔════════════════════════════════════════════════════╗"
echo "║  📊 ĐO TỐC ĐỘ SLICE eMBB (SST=1 / TBF 100Mbps)   ║"
echo "║  ▶️  Video đang play = thấy Download tăng!          ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
printf "%-6s %-12s %-12s %-12s %-15s\n" \
  "Giây" "YouTube↓" "Upload↑" "Giới hạn" "Trạng thái"
echo "──────────────────────────────────────────────────────────"

SEC=0
MAX_DOWN=0

while true; do
  # tx = UPF → UE = YouTube download
  # rx = UE → UPF = upload
  TX1=$(docker exec upf-embb cat /sys/class/net/ogstun/statistics/tx_bytes 2>/dev/null || echo 0)
  RX1=$(docker exec upf-embb cat /sys/class/net/ogstun/statistics/rx_bytes 2>/dev/null || echo 0)
  sleep 1
  TX2=$(docker exec upf-embb cat /sys/class/net/ogstun/statistics/tx_bytes 2>/dev/null || echo 0)
  RX2=$(docker exec upf-embb cat /sys/class/net/ogstun/statistics/rx_bytes 2>/dev/null || echo 0)

  SEC=$((SEC+1))

  DOWN_MBPS=$(awk "BEGIN {printf \"%.1f\", ($TX2-$TX1)*8/1000000}")
  UP_MBPS=$(awk "BEGIN {printf \"%.1f\", ($RX2-$RX1)*8/1000000}")
  DOWN_INT=$(awk "BEGIN {printf \"%d\", ($TX2-$TX1)*8/1000000}")

  [ "$DOWN_INT" -gt "$MAX_DOWN" ] 2>/dev/null && MAX_DOWN=$DOWN_INT

  # Progress bar /100Mbps
  BAR_LEN=$(( DOWN_INT > 100 ? 10 : DOWN_INT / 10 ))
  BAR=""
  for i in $(seq 1 $BAR_LEN 2>/dev/null); do BAR="${BAR}█"; done
  while [ ${#BAR} -lt 10 ]; do BAR="${BAR}░"; done

  if   [ "$DOWN_INT" -ge 50 ] 2>/dev/null; then STATUS="🔥 HD/4K"
  elif [ "$DOWN_INT" -ge 20 ] 2>/dev/null; then STATUS="▶️  720p"
  elif [ "$DOWN_INT" -ge 5  ] 2>/dev/null; then STATUS="📡 Đang load"
  elif [ "$DOWN_INT" -ge 1  ] 2>/dev/null; then STATUS="🌐 Nhỏ"
  else STATUS="💤 Idle"; fi

  printf "%-6s [%s] %-12s %-12s %-15s MAX: %s Mbps\n" \
    "${SEC}s" "$BAR" \
    "${DOWN_MBPS} Mbps" \
    "${UP_MBPS} Mbps" \
    "$STATUS" \
    "$MAX_DOWN"
done
