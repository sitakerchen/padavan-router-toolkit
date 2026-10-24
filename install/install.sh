#!/bin/sh
# Padavan Router Toolkit 安装脚本
#
# 在路由器上执行（不是在本机）：
#   scp -r . admin@192.168.123.1:/tmp/padavan-toolkit
#   ssh admin@192.168.123.1 '/tmp/padavan-toolkit/install/install.sh'
#
# 或者在本机执行（需要 sshpass）：
#   ./install/install.sh
#
set -e

# ============ 配置区 ============
ROUTER_HOST="${ROUTER_HOST:-192.168.123.1}"
ROUTER_USER="${ROUTER_USER:-admin}"
ROUTER_PASS="${ROUTER_PASS:-admin}"

# U 盘分区 UUID（用 blkid 查看，必须修改成你自己的）
OPT_UUID="${OPT_UUID:-6637de50-514f-4270-9309-5edc2f3d388b}"
DATA_UUID="${DATA_UUID:-aab01a63-4fc6-4026-b709-ec16c4e596e2}"

SWAP_SIZE_MB="${SWAP_SIZE_MB:-128}"
# ================================

log()  { printf '\033[36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 判断执行环境 ----------
if [ -f /etc/storage/started_script.sh ]; then
    ON_ROUTER=1
else
    ON_ROUTER=0
fi

if [ "$ON_ROUTER" = "0" ]; then
    command -v sshpass >/dev/null 2>&1 || die "本机执行需要 sshpass（brew install sshpass）"
    SRC_DIR=$(cd "$(dirname "$0")/.." && pwd)
    log "从本机部署到 $ROUTER_USER@$ROUTER_HOST"

    # 打包上传
    TMP_TAR=$(mktemp -t padavan-toolkit.XXXXXX).tar.gz
    trap 'rm -f "$TMP_TAR"' EXIT
    COPYFILE_DISABLE=1 tar -czf "$TMP_TAR" -C "$SRC_DIR" \
        --exclude '._*' --exclude '.DS_Store' --exclude '.git' .
    log "上传中..."
    SSHPASS="$ROUTER_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$ROUTER_USER@$ROUTER_HOST" 'rm -rf /tmp/padavan-toolkit && mkdir -p /tmp/padavan-toolkit'
    SSHPASS="$ROUTER_PASS" sshpass -e tar -xzf "$TMP_TAR" -C /dev/null 2>/dev/null || true
    COPYFILE_DISABLE=1 tar -czf - -C "$SRC_DIR" --exclude '._*' --exclude '.DS_Store' --exclude '.git' . \
        | SSHPASS="$ROUTER_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$ROUTER_USER@$ROUTER_HOST" 'cd /tmp/padavan-toolkit && tar -xzf -'

    log "在路由器上执行安装..."
    SSHPASS="$ROUTER_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$ROUTER_USER@$ROUTER_HOST" \
        "OPT_UUID='$OPT_UUID' DATA_UUID='$DATA_UUID' SWAP_SIZE_MB='$SWAP_SIZE_MB' /tmp/padavan-toolkit/install/install.sh"
    exit $?
fi

# ---------- 以下在路由器上执行 ----------
SRC_DIR=/tmp/padavan-toolkit
[ -d "$SRC_DIR" ] || SRC_DIR=$(cd "$(dirname "$0")/.." && pwd)

export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
export LD_LIBRARY_PATH=/opt/lib:/opt/usr/lib:/lib:/usr/lib

ENTWARE_MNT=/media/opt
DATA_MNT=/media/Data

find_dev() {
    for d in /dev/sd[a-z][0-9]; do
        [ -b "$d" ] || continue
        uuid=$(blkid -s UUID -o value "$d" 2>/dev/null)
        [ "$uuid" = "$1" ] && echo "$d" && return 0
    done
    return 1
}

# ---------- 1. 检查 U 盘 ----------
log "检查 U 盘分区..."
OPT_DEV=$(find_dev "$OPT_UUID") || die "找不到 opt 分区（UUID=$OPT_UUID）"
DATA_DEV=$(find_dev "$DATA_UUID") || die "找不到 Data 分区（UUID=$DATA_UUID）"
ok "opt=$OPT_DEV  data=$DATA_DEV"

# ---------- 2. 挂载 ----------
log "挂载分区..."
modprobe ext4 2>/dev/null || true
mkdir -p "$ENTWARE_MNT" "$DATA_MNT"
mountpoint -q "$ENTWARE_MNT" || mount -t ext4 "$OPT_DEV" "$ENTWARE_MNT"
mountpoint -q "$DATA_MNT"   || mount -t ext4 "$DATA_DEV" "$DATA_MNT"
ok "已挂载"

# ---------- 3. 安装 Entware ----------
log "检查 Entware..."
if [ ! -x "$ENTWARE_MNT/bin/opkg" ]; then
    log "下载 opkg..."
    mkdir -p "$ENTWARE_MNT/bin" "$ENTWARE_MNT/etc/opkg" "$ENTWARE_MNT/lib" \
             "$ENTWARE_MNT/sbin" "$ENTWARE_MNT/usr/bin" "$ENTWARE_MNT/usr/sbin" \
             "$ENTWARE_MNT/usr/lib" "$ENTWARE_MNT/usr/share" \
             "$ENTWARE_MNT/var/lib/opkg" "$ENTWARE_MNT/var/lock" \
             "$ENTWARE_MNT/var/log" "$ENTWARE_MNT/tmp" "$ENTWARE_MNT/root"

    cd /tmp
    wget -q -T 60 "http://bin.entware.net/mipselsf-k3.4/Packages" -O /tmp/Packages || die "下载包索引失败"
    OPKG_FILE=$(awk '/^Package: opkg$/,/^$/' /tmp/Packages | grep '^Filename:' | head -1 | awk '{print $2}')
    [ -n "$OPKG_FILE" ] || die "包索引里找不到 opkg"
    wget -q -T 60 "http://bin.entware.net/mipselsf-k3.4/$OPKG_FILE" -O /tmp/opkg.ipk || die "下载 opkg 失败"
    tar -xzf /tmp/opkg.ipk -C /tmp data.tar.gz
    tar -xzf /tmp/data.tar.gz -C "$ENTWARE_MNT"
    # 包内路径是 ./opt/bin/opkg，需要移动到 bin/
    if [ -f "$ENTWARE_MNT/opt/bin/opkg" ]; then
        mv "$ENTWARE_MNT/opt/bin/opkg" "$ENTWARE_MNT/bin/opkg"
        rmdir "$ENTWARE_MNT/opt/bin" "$ENTWARE_MNT/opt" 2>/dev/null || true
    fi
    chmod +x "$ENTWARE_MNT/bin/opkg"
    ok "opkg 已安装"
fi

# ---------- 4. 配置 bind mount ----------
log "配置 /opt bind mount..."
for d in bin lib sbin usr var share; do
    mkdir -p "/opt/$d" "$ENTWARE_MNT/$d"
    mountpoint -q "/opt/$d" || mount -o bind "$ENTWARE_MNT/$d" "/opt/$d"
done
mkdir -p /opt/etc /opt/tmp /opt/var/log/nginx /opt/var/run /opt/etc/nginx
cp -f /etc/passwd /opt/etc/passwd 2>/dev/null || true
cp -f /etc/group  /opt/etc/group  2>/dev/null || true
ok "/opt 已就绪"

# ---------- 5. 配置 opkg ----------
log "配置 opkg..."
cp -f "$SRC_DIR/config/opkg.conf" "$ENTWARE_MNT/etc/opkg.conf"
cp -f "$SRC_DIR/config/opkg.conf" /opt/etc/opkg.conf
ok "opkg 配置完成"

# ---------- 6. 安装 nginx ----------
log "检查 nginx..."
if [ ! -x /opt/sbin/nginx ]; then
    log "安装 nginx（约 10MB，需要几分钟）..."
    /opt/bin/opkg update
    /opt/bin/opkg install nginx
    ok "nginx 已安装"
else
    ok "nginx 已存在"
fi

# ---------- 7. 部署配置 ----------
log "部署配置..."
mkdir -p "$ENTWARE_MNT/etc/nginx"
cp -f "$SRC_DIR/config/nginx-remember-me.conf" "$ENTWARE_MNT/etc/nginx/remember-me.conf"
cp -f "$SRC_DIR/config/nginx-remember-me.conf" /opt/etc/nginx/remember-me.conf
ok "nginx 配置已部署"

# ---------- 8. 部署脚本 ----------
log "部署脚本到 /etc/storage..."
for f in remember-me-start.sh remember-me-watchdog.sh monitor-gen.sh monitor-loop.sh; do
    cp -f "$SRC_DIR/scripts/$f" "/etc/storage/$f"
    chmod 755 "/etc/storage/$f"
done
ok "脚本已部署"

# 替换脚本里的 UUID
sed -i "s|^OPT_UUID=.*|OPT_UUID=$OPT_UUID|"   /etc/storage/remember-me-start.sh
sed -i "s|^DATA_UUID=.*|DATA_UUID=$DATA_UUID|" /etc/storage/remember-me-start.sh
sed -i "s|^OPT_UUID=.*|OPT_UUID=$OPT_UUID|"   /etc/storage/remember-me-watchdog.sh
sed -i "s|^DATA_UUID=.*|DATA_UUID=$DATA_UUID|" /etc/storage/remember-me-watchdog.sh
sed -i "s|count=128|count=$SWAP_SIZE_MB|"     /etc/storage/remember-me-start.sh
ok "UUID 已写入脚本"

# ---------- 9. 部署监控页 ----------
log "部署状态监控页..."
mkdir -p "$DATA_MNT/www/remember-me"
cp -f "$SRC_DIR/www/status.html" "$DATA_MNT/www/remember-me/status.html"
ok "监控页已部署"

# ---------- 10. 开机自启 ----------
log "配置开机自启..."
HOOK='# RememberMe 前端服务（nginx :8080）'
if ! grep -q "$HOOK" /etc/storage/started_script.sh 2>/dev/null; then
    cat >> /etc/storage/started_script.sh <<'EOF'

# RememberMe 前端服务（nginx :8080）
[ -x /etc/storage/remember-me-start.sh ] && /etc/storage/remember-me-start.sh &
# RememberMe 守护进程：U 盘掉线后自动等待并恢复服务
[ -x /etc/storage/remember-me-watchdog.sh ] && /etc/storage/remember-me-watchdog.sh &
EOF
    ok "开机自启已配置"
else
    ok "开机自启已存在"
fi

# ---------- 11. 启动服务 ----------
log "启动服务..."
/etc/storage/remember-me-start.sh || warn "启动脚本返回非 0（可能 U 盘未就绪）"

if ! pgrep -f "remember-me-watchdog" >/dev/null 2>&1; then
    /etc/storage/remember-me-watchdog.sh >/dev/null 2>&1 &
fi
ok "服务已启动"

# ---------- 12. 保存到 flash ----------
log "保存配置到 flash..."
sync
/sbin/mtd_storage.sh save 2>&1 | tail -1

# ---------- 13. 验证 ----------
log "验证..."
sleep 2
if [ -f /tmp/remember-me.log ]; then
    tail -8 /tmp/remember-me.log
fi

echo
ok "安装完成"
echo
echo "  状态监控: http://$ROUTER_HOST:8080/status.html"
echo "  启动日志: ssh $ROUTER_USER@$ROUTER_HOST 'cat /tmp/remember-me.log'"
