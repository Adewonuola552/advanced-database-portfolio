#!/usr/bin/env bash
# Start a local single-node MongoDB replica set for Portfolio 4.
# Multi-document transactions need a replica set, so even one node is started as one.
# Data lives in .mongo-data/ (git-ignored). Stop with: ./start_mongo.sh stop
set -euo pipefail
cd "$(dirname "$0")"
PORT=27117
DATA=.mongo-data

if [[ "${1:-}" == "stop" ]]; then
    mongosh --quiet --port $PORT --eval 'db.getSiblingDB("admin").shutdownServer()' || true
    exit 0
fi

mkdir -p "$DATA"
if ! mongosh --quiet --port $PORT --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1; then
    mongod --replSet clearpay-rs --port $PORT --bind_ip 127.0.0.1 --dbpath "$DATA" \
           --wiredTigerCacheSizeGB 1 --fork --logpath "$DATA/mongod.log"
fi
mongosh --quiet --port $PORT --eval '
    try { rs.status() } catch (e) {
        rs.initiate({_id: "clearpay-rs", members: [{_id: 0, host: "127.0.0.1:27117"}]});
    }
    while (!db.hello().isWritablePrimary) { sleep(200) }
    print("MongoDB " + db.version() + " replica set " + db.hello().setName + " ready on port 27117")'
