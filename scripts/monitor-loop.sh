#!/bin/sh
# 每 30 秒刷新一次 status.json
while true; do
    /etc/storage/monitor-gen.sh
    sleep 30
done
