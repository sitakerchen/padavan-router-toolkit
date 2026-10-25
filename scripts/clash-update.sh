#!/bin/sh
# Clash 订阅自动更新
#
# 从 nvram app_91 读取订阅链接，下载后：
#   1. 修正路由器需要的配置（allow-lan / mixed-port / external-controller）
#   2. 关闭 GeoSite 加载（geoip: false）
#   3. 写入 U 盘模板
#   4. 重启 clash
#
# 由 crontab 每 6 小时调用一次。

LOG=/tmp/remember-me.log
log() { echo "[$(date '+%F %T')] [clash-update] $*" >> $LOG; }

PATH=/sbin:/usr/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
export PATH

CLASH_DIR=/opt/app/clash/config
CLASH_CFG=$CLASH_DIR/config.yaml
CLASH_TPL=/media/opt/app/clash/config/config.yaml.persist
TMP=/tmp/clash-sub.yaml

# 1. 读取订阅链接
SUB_URL=$(nvram get app_91 2>/dev/null)
if [ -z "$SUB_URL" ]; then
    log "未配置订阅链接（nvram app_91），跳过"
    exit 0
fi

# 2. 下载
log "开始更新订阅"
rm -f "$TMP"
wget -q -T 30 -t 2 -O "$TMP" "$SUB_URL" 2>/dev/null
if [ ! -s "$TMP" ]; then
    curl -sL -m 30 --user-agent "clash" -o "$TMP" "$SUB_URL" 2>/dev/null
fi
if [ ! -s "$TMP" ]; then
    log "下载失败，保留现有配置"
    rm -f "$TMP"
    exit 1
fi

# 3. 校验是 YAML 且含 proxies
if ! grep -q "^proxies:" "$TMP"; then
    log "下载内容不是有效配置（无 proxies 段），放弃"
    rm -f "$TMP"
    exit 1
fi

# 4. 修正路由器需要的配置
#    allow-lan：允许局域网设备使用
#    mixed-port：HTTP+SOCKS5 混合端口
#    external-controller：面板监听地址
#    log-level：info 便于排查
#    geoip: false：关闭 GeoSite 加载（省 50MB 内存）
sed -i "s|^allow-lan:.*|allow-lan: true|" "$TMP"
sed -i "s|^external-controller:.*|external-controller: 192.168.123.1:27428|" "$TMP"
sed -i "s|^log-level:.*|log-level: info|" "$TMP"
sed -i "s|^    geoip: true|    geoip: false|" "$TMP"

# 移除订阅自带的端口配置（避免和固件冲突）
sed -i "/^port: /d; /^socks-port: /d; /^redir-port: /d; /^tproxy-port: /d" "$TMP"

# 移除 geosite 引用（会触发从 GitHub 下载 GeoSite.dat，国内超时导致启动失败）
# nameserver-policy 里的 geosite:cn / geosite:geolocation-!cn 改成普通域名匹配
sed -i "/'geosite:cn'/d; /'geosite:geolocation-!cn'/d; /\"geosite:cn\"/d; /\"geosite:geolocation-!cn\"/d" "$TMP"
# 规则里的 GEOSITE 也移除（保留 GEOIP）
sed -i "/GEOSITE,/d" "$TMP"

# 确保 mixed-port 存在
if ! grep -q "^mixed-port:" "$TMP"; then
    sed -i "/^allow-lan:/a mixed-port: 7893" "$TMP"
fi

# 确保 external-ui 存在（Web 面板，否则 /ui/ 返回 404）
if ! grep -q "^external-ui:" "$TMP"; then
    sed -i "/^external-controller:/a external-ui: clash_webs" "$TMP"
fi

# 确保 secret 非空（面板密钥，订阅里可能是空值）
SECRET=$(nvram get clash_secret 2>/dev/null)
[ -z "$SECRET" ] && SECRET="c53aa476e"
sed -i "/^secret:/d" "$TMP"
sed -i "/^external-controller:/a secret: $SECRET" "$TMP"

# 5. 写入模板
mkdir -p "$(dirname "$CLASH_TPL")"
cp -f "$TMP" "$CLASH_TPL"
cp -f "$TMP" "$CLASH_CFG"
rm -f "$TMP"

# 6. 重启 clash
log "订阅已更新，重启 clash"
for p in $(ps | grep "[c]lash -d" | grep -v grep | cut -c1-5); do
    kill -9 "$p" 2>/dev/null
done

sleep 2
mkdir -p "$CLASH_DIR"
# 恢复 MMDB（如果丢了）
[ ! -f "$CLASH_DIR/geoip.metadb" ] && [ -f /media/opt/app/clash/config/geoip.metadb ] && \
    cp -f /media/opt/app/clash/config/geoip.metadb "$CLASH_DIR/geoip.metadb"

nohup /opt/bin/clash -d "$CLASH_DIR" >/tmp/clash.log 2>&1 < /dev/null &
log "clash 已重启"
