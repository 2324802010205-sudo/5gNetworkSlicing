#!/bin/bash
set -euo pipefail

TAIL_LINES="${TAIL_LINES:-500}"
FAIL=0
WARN=0
RUNTIME_CONFIRMED=0

container_state() {
    docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

log_has() {
    local name="$1"
    local pattern="$2"
    docker logs "$name" --tail "$TAIL_LINES" 2>&1 | grep -Eiq "$pattern"
}

pass() { echo "PASS: $1"; }
warn() { echo "WARN: $1"; WARN=$((WARN+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "NSSF verification"

if [ "$(container_state nssf)" = "running" ]; then
    pass "nssf container is running"
else
    fail "nssf container is not running"
fi

if log_has nssf 'nssf|NF registered|Register NF Instance|SBI|server'; then
    pass "nssf log is present and shows service activity"
else
    warn "nssf log does not show clear service activity"
fi

if log_has nrf 'nssf|NF registered.*NSSF|NSSF.*registered|nfType.*NSSF'; then
    pass "nrf log shows NSSF registration evidence"
else
    warn "nrf log does not clearly show NSSF registration"
fi

if log_has amf 'nssf|NSSelection|nnssf|slice selection|network slice selection'; then
    pass "amf log mentions NSSF or network slice selection"
    RUNTIME_CONFIRMED=1
else
    warn "amf log does not clearly show runtime NSSF selection"
fi

if [ "$RUNTIME_CONFIRMED" -eq 0 ]; then
    echo "NSSF service is present, but runtime NS selection is not confirmed. Current slicing may still rely on static AMF/SMF configuration."
fi

echo "Summary: WARN=$WARN FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
