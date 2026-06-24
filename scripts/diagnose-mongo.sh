#!/bin/bash
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "============================================================"
echo " MongoDB resource and WiredTiger diagnostic"
echo "============================================================"

if ! docker inspect mongo >/dev/null 2>&1; then
    echo "ERROR: mongo container does not exist." >&2
    exit 1
fi

MONGO_STATE=$(docker inspect -f '{{.State.Status}}' mongo 2>/dev/null || true)
echo
echo "Container state: ${MONGO_STATE:-unknown}"

echo
echo "[1/3] docker stats mongo --no-stream"
docker stats mongo --no-stream \
    --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.BlockIO}}\t{{.PIDs}}'

echo
echo "[2/3] WiredTiger cache"
if [ "$MONGO_STATE" != "running" ]; then
    echo "Mongo is not running; WiredTiger statistics are unavailable."
else
    docker exec mongo mongosh --quiet mongodb://127.0.0.1:27017/admin --eval '
const status = db.serverStatus();
print("storageEngine=" + status.storageEngine.name);
printjson(status.wiredTiger.cache);
'
fi

echo
echo "[3/3] free -h"
free -h

echo
echo "Key fields to compare:"
echo "- maximum bytes configured"
echo "- bytes currently in the cache"
echo "- pages read into cache / pages written from cache"
echo "- operations timed out waiting for space in cache"
echo "- Docker memory percentage and block I/O"
