#!/bin/sh
# RememberMe 守护进程
#
# 职责：
#   1. 持续检测 U 盘是否就绪（按 UUID 查找，不受 sda/sdb 变化影响）
#   2. U 盘可用时确保服务在跑（nginx / clash / swap / 监控）
#   3. U 盘掉线时不做破坏性操作，等它回来
#   4. U 盘重新插上后自动恢复所有服务
#
# 这个脚本本身不依赖 U 盘，跑在内存里。

LOG=/tmp/remember-me.log
log() { echo "[$(date '+%F %T')] [watchdog] $*" >> $LOG; }


# 单例保护：用 flock 文件锁（比 PID 文件可靠）
LOCKFILE=/tmp/remember-me-watchdog.lock
exec 9>$LOCKFILE
if ! flock -n 9; then
    echo "[watchdog] 已有实例在运行，退出" >> /tmp/remember-me.log
    exit 0
fi
OPT_UUID=6637de50-514f-4270-9309-5edc2f3d388b
DATA_UUID=aab01a63-4fc6-4026-b709-ec16c4e596e2

ENTWARE_MNT=/media/opt
DATA_MNT=/media/Data
SWAPFILE=$DATA_MNT/swapfile
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib:/lib:/usr/lib

# 按 UUID 找设备，找不到输出空
find_dev() {
    for d in /dev/sd[a-z][0-9]; do
        [ -b "$d" ] || continue
        uuid=$(/sbin/blkid -s UUID -o value "$d" 2>/dev/null)
        [ "$uuid" = "$1" ] && echo "$d" && return 0
    done
    return 1
}

disk_ready() {
    mountpoint -q "$ENTWARE_MNT" || return 1
    mountpoint -q "$DATA_MNT" || return 1
    ls "$DATA_MNT" >/dev/null 2>&1 || return 1
    ls "$ENTWARE_MNT" >/dev/null 2>&1 || return 1
    return 0
}

# 卸载固件 automount 挂到 /media/AiDisk_* 的分区
clear_firmware_mounts() {
    for m in $(mount | awk '$3 ~ /^\/media\/AiDisk/ {print $3}'); do
        umount "$m" 2>/dev/null && log "已卸载固件挂载 $m"
    done
}

ensure_services() {
    if [ -x /opt/sbin/nginx ] && [ -f /opt/etc/nginx/remember-me.conf ]; then
        if ! pidof nginx >/dev/null 2>&1; then
            /opt/sbin/nginx -c /opt/etc/nginx/remember-me.conf 2>/dev/null \
                && log "nginx 已启动" || log "nginx 启动失败"
        fi
    fi

    # clash：先确认配置就绪再启动（避免读到默认空配置）
    if [ "$(nvram get clash_enable 2>/dev/null)" = "1" ] && [ -x /opt/bin/clash ]; then
        CLASH_CFG=/opt/app/clash/config/config.yaml
        if [ ! -s "$CLASH_CFG" ] || ! grep -q "^proxies:" "$CLASH_CFG" 2>/dev/null; then
            clash_wait=$(( ${clash_wait:-0} + 1 ))
            if [ "$clash_wait" -ge 6 ]; then
                log "配置等待超时，主动触发固件生成"
                /etc/storage/script/Sh10_clash.sh restart >/dev/null 2>&1 &
                clash_wait=0
            else
                log "clash 配置未就绪，等待固件生成 ($clash_wait/6)"
            fi
        else
            # 确保 GeoSite 优化没被订阅更新覆盖
            if grep -q "^    geoip: true" "$CLASH_CFG" 2>/dev/null; then
                sed -i "s|^    geoip: true|    geoip: false|" "$CLASH_CFG"
                log "已重新应用 geoip 优化"
            fi
            # MMDB 持久化在 U 盘，缺失时恢复（GitHub 下载会超时）
            if [ ! -f /opt/app/clash/config/geoip.metadb ] && [ -f /media/Data/clash-data/geoip.metadb ]; then
                cp /media/Data/clash-data/geoip.metadb /opt/app/clash/config/geoip.metadb
                log "已从 U 盘恢复 MMDB"
            fi
            clash_count=$(pgrep -f "clash -d" 2>/dev/null | wc -l)
            if [ "$clash_count" -eq 0 ]; then
                log "clash 未运行，启动"
                nohup /opt/bin/clash -d /opt/app/clash/config >/tmp/clash.log 2>&1 < /dev/null &
            elif [ "$clash_count" -gt 1 ]; then
                log "清理 $clash_count 个 clash 实例"
                for p in $(pgrep -f "clash -d" | tail -n +2); do
                    kill -9 "$p" 2>/dev/null
                done
            fi
        fi
    fi

    if [ -f "$SWAPFILE" ] && ! grep -q "$SWAPFILE" /proc/swaps 2>/dev/null; then
        /sbin/swapon "$SWAPFILE" 2>/dev/null && log "swap 已启用" || log "swap 启用失败"
    fi

    if ! pgrep -f "monitor-loop" >/dev/null 2>&1; then
        /etc/storage/monitor-loop.sh >/dev/null 2>&1 &
        log "状态监控已启动"
    fi
}

log "守护进程启动"

was_ready=0
while true; do
    if disk_ready; then
        if [ "$was_ready" = "0" ]; then
            log "U 盘就绪，开始恢复服务"
            /etc/storage/remember-me-start.sh >/dev/null 2>&1
            was_ready=1
        fi
        ensure_services
        sleep 30
    else
        if [ "$was_ready" = "1" ]; then
            log "U 盘掉线，等待重新接入"
            was_ready=0
        fi

        opt_dev=$(find_dev "$OPT_UUID")
        data_dev=$(find_dev "$DATA_UUID")
        if [ -n "$opt_dev" ] && [ -n "$data_dev" ]; then
            log "发现设备 $opt_dev / $data_dev"
            modprobe ext4 2>/dev/null
            clear_firmware_mounts
            mkdir -p "$ENTWARE_MNT" "$DATA_MNT"
            mountpoint -q "$ENTWARE_MNT" || mount -t ext4 "$opt_dev" "$ENTWARE_MNT" 2>/dev/null
            mountpoint -q "$DATA_MNT" || mount -t ext4 "$data_dev" "$DATA_MNT" 2>/dev/null
        fi
        sleep 10
    fi
done
