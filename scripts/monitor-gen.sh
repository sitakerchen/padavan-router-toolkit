#!/bin/sh
# 生成系统监控数据 JSON
OUT=/media/Data/www/remember-me/status.json
TMP=$OUT.tmp

MEMTOTAL=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MEMFREE=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
MEMAVAIL=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
BUFFERS=$(awk '/^Buffers:/{print $2}' /proc/meminfo)
CACHED=$(awk '/^Cached:/{print $2}' /proc/meminfo)
SWAPTOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAPFREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)

[ -z "$MEMAVAIL" ] && MEMAVAIL=$(( MEMFREE + BUFFERS + CACHED ))

LOAD=$(awk '{print $1","$2","$3}' /proc/loadavg)
UPTIME=$(awk '{print int($1)}' /proc/uptime)
DISK_OPT=$(df -k /media/opt 2>/dev/null | awk 'NR==2{print $2","$3","$4}')
DISK_DATA=$(df -k /media/Data 2>/dev/null | awk 'NR==2{print $2","$3","$4}')

NGINX=$(pidof nginx >/dev/null 2>&1 && echo 1 || echo 0)
CLASH=$(pidof clash >/dev/null 2>&1 && echo 1 || echo 0)

cat > "$TMP" <<EOF
{"ts":$(date +%s),"mem":{"total":$MEMTOTAL,"free":$MEMFREE,"avail":$MEMAVAIL,"buffers":$BUFFERS,"cached":$CACHED},"swap":{"total":$SWAPTOTAL,"free":$SWAPFREE},"load":[$LOAD],"uptime":$UPTIME,"disk":{"opt":[$DISK_OPT],"data":[$DISK_DATA]},"svc":{"nginx":$NGINX,"clash":$CLASH}}
EOF
mv "$TMP" "$OUT"
