#!/bin/bash
set -u

echo "nproc"
nproc

echo
echo 'lscpu | grep -E "CPU\(s\)|Socket|Core|Thread"'
lscpu | grep -E 'CPU\(s\)|Socket|Core|Thread' || true

echo
echo "free -h"
free -h

echo
echo "swapon --show"
swapon --show || true

echo
echo "docker stats --no-stream"
docker stats --no-stream || true

AVAILABLE_BYTES=$(free -b | awk '/^Mem:/ {print $7}')
LOW_RAM_BYTES=$((1536 * 1024 * 1024))
if [ -n "${AVAILABLE_BYTES:-}" ] && [ "$AVAILABLE_BYTES" -lt "$LOW_RAM_BYTES" ]; then
    echo
    echo "WARNING: Low available RAM. Stop optional containers before running experiments."
fi

if ! swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
    echo
    echo "WARNING: No swap detected. Consider adding 4GB swap for 5GB RAM VM."
fi
