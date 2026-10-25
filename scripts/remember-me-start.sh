#!/bin/sh
# RememberMe 前端服务启动脚本（由 started_script.sh 和 watchdog 调用）
#
# 布局：U 盘 = Entware(ext4, 2GB) + Data(ext4, 剩余)
# 设备按 UUID 识别，不受 sda/sdb 重新枚举影响。
# 本脚本幂等，可重复执行。

LOG=/tmp/remember-me.log
log() { echo "[$(date '+%F %T')] $*" >> $LOG; }

OPT_UUID=6637de50-514f-4270-9309-5edc2f3d388b
DATA_UUID=aab01a63-4fc6-4026-b709-ec16c4e596e2

ENTWARE_MNT=/media/opt
DATA_MNT=/media/Data
SWAPFILE=$DATA_MNT/swapfile
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib:/lib:/usr/lib

find_dev() {
    for d in /dev/sd[a-z][0-9]; do
        [ -b "$d" ] || continue
        uuid=$(/sbin/blkid -s UUID -o value "$d" 2>/dev/null)
        [ "$uuid" = "$1" ] && echo "$d" && return 0
    done
    return 1
}

log "=== RememberMe 启动 ==="

# 1. 等待 U 盘设备就绪（最多 20 秒）
#    超时不算失败：守护进程 remember-me-watchdog.sh 会持续重试
i=0
while [ $i -lt 10 ]; do
    ENTWARE_DEV=$(find_dev "$OPT_UUID")
    DATA_DEV=$(find_dev "$DATA_UUID")
    [ -n "$ENTWARE_DEV" ] && [ -n "$DATA_DEV" ] && break
    sleep 2
    i=$((i + 1))
done
if [ -z "$ENTWARE_DEV" ] || [ -z "$DATA_DEV" ]; then
    log "U 盘未就绪，交由守护进程继续等待"
    exit 1
fi
log "设备: $ENTWARE_DEV / $DATA_DEV"

modprobe ext4 2>/dev/null

# 2. 清理固件 automount 的错误挂载
#    automount.sh 会把分区挂到 /opt 或 /media/AiDisk_*，必须先拆掉
for m in $(mount | awk '$3 ~ /^\/www\// {print $3}'); do
    umount "$m" 2>/dev/null
done
for m in $(mount | awk '$3 ~ /^\/media\/AiDisk/ {print $3}'); do
    umount "$m" 2>/dev/null && log "已卸载固件挂载 $m"
done
for d in bin lib sbin usr var share; do
    mount | grep -q " on /opt/$d " && umount -l /opt/$d 2>/dev/null
done
if mount | grep -q "^/dev/sd.* on /opt "; then
    umount -l /opt 2>/dev/null
    log "已移除固件在 /opt 上的错误挂载"
fi
# 恢复 /opt 为可写 tmpfs
mountpoint -q /opt || mount -t tmpfs -o size=62464k tmpfs /opt

# 3. 挂载分区
mkdir -p $ENTWARE_MNT $DATA_MNT
mountpoint -q $ENTWARE_MNT || mount -t ext4 $ENTWARE_DEV $ENTWARE_MNT 2>/dev/null
mountpoint -q $DATA_MNT || mount -t ext4 $DATA_DEV $DATA_MNT 2>/dev/null

if ! mountpoint -q $ENTWARE_MNT || ! mountpoint -q $DATA_MNT; then
    log "分区挂载失败，交由守护进程重试"
    exit 2
fi

# 4. 把 Entware 子目录 bind 到 /opt（/opt 本身保持 tmpfs，不破坏固件）
for d in bin lib sbin usr var share; do
    mkdir -p /opt/$d
    mountpoint -q /opt/$d || mount -o bind $ENTWARE_MNT/$d /opt/$d
done

# clash 配置目录持久化（避免冷复位后丢失，GitHub 下载 MMDB 会超时）
mkdir -p /opt/app $ENTWARE_MNT/app
mountpoint -q /opt/app || mount -o bind $ENTWARE_MNT/app /opt/app
mkdir -p /opt/etc /opt/tmp /opt/var/log/nginx /opt/var/run
cp -f /etc/passwd /opt/etc/passwd 2>/dev/null
cp -f /etc/group  /opt/etc/group  2>/dev/null

# nginx 配置持久化在 U 盘上，每次启动复制到 /opt/etc/nginx
mkdir -p /opt/etc/nginx
cp -f $ENTWARE_MNT/etc/nginx/remember-me.conf /opt/etc/nginx/remember-me.conf 2>/dev/null

# opkg 配置同样持久化在 U 盘上
cp -f $ENTWARE_MNT/etc/opkg.conf /opt/etc/opkg.conf 2>/dev/null
mkdir -p /opt/var/lib/opkg /opt/usr/bin /opt/usr/sbin /opt/usr/lib /opt/usr/share /opt/root

export LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib:/lib:/usr/lib

# 5. 启动 nginx
if [ -x /opt/sbin/nginx ] && [ -f /opt/etc/nginx/remember-me.conf ]; then
    if ! pidof nginx >/dev/null 2>&1; then
        /opt/sbin/nginx -c /opt/etc/nginx/remember-me.conf
        log "nginx 已启动 (端口 8080)"
    else
        log "nginx 已在运行"
    fi
else
    log "nginx 或配置缺失 (nginx=$([ -x /opt/sbin/nginx ] && echo ok || echo missing))"
fi

# 6. 启用 swap（128MB，放在 Data 分区）
if [ ! -f "$SWAPFILE" ]; then
    log "创建 swap 文件 128MB ..."
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=128 2>/dev/null
    chmod 600 "$SWAPFILE"
    /sbin/mkswap "$SWAPFILE" >/dev/null 2>&1
fi
if ! grep -q "$SWAPFILE" /proc/swaps 2>/dev/null; then
    /sbin/swapon "$SWAPFILE" 2>/dev/null && log "swap 已启用 (128MB)" || log "swap 启用失败"
else
    log "swap 已在运行"
fi

# 7. 启动状态监控（每 30 秒生成 status.json）
if ! pgrep -f "monitor-loop" >/dev/null 2>&1; then
    /etc/storage/monitor-loop.sh >/dev/null 2>&1 &
    log "状态监控已启动"
fi
