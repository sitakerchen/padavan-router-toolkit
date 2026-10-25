# 性能优化记录

## 优化 1：clash 启动时间从 87 秒降到 0.56 秒

### 问题

clash 启动耗时 87.7 秒，内存占用 105MB，swap 用了 104MB。代理请求全部超时。

### 排查

日志显示：

```
Start initial configuration in progress
Geodata Loader mode: memconservative
Geosite Matcher implementation: succinct
Can't find GeoSite.dat, start download
Download GeoSite.dat finish
Load GeoSite rule: cn
Finished initial GeoSite rule cn => dns.nameserver-policy, records: 110448
Load GeoSite rule: geolocation-!cn
Finished initial GeoSite rule geolocation-!cn => dns.nameserver-policy, records: 27420
Initial configuration complete, total time: 87713ms
```

**GeoSite 展开了 13.7 万条记录**，这才是内存和时间的真凶。

但配置文件里根本搜不到 `geosite`：

```sh
grep -i geosite /opt/app/clash/config/config.yaml
# 无结果
```

### 根因

`fallback-filter.geoip: true` 会触发 mihomo **自动加载 GeoSite 数据库**，即使配置里没有显式引用。

```yaml
dns:
  fallback-filter:
    geoip: true        # ← 这一行
    geoip-code: CN
```

### 解决

改成 `false`：

```yaml
dns:
  fallback-filter:
    geoip: false
    geoip-code: CN
```

### 影响评估

配置里有 1 条 `GEOIP,CN` 规则，需要 GeoIP 数据库。但：

| 文件 | 大小 | 用途 |
|---|---|---|
| `Country.mmdb` | 403KB | GeoIP（IP 归属） |
| `GeoSite.dat` | 4.1MB | GeoSite（域名分类） |

`GEOIP,CN` 只用 `Country.mmdb`，**不需要 GeoSite**。所以关掉 `fallback-filter.geoip` 不影响分流。

### 结果

| 指标 | 优化前 | 优化后 | 提升 |
|---|---|---|---|
| 启动时间 | 87.7 秒 | **0.56 秒** | **156x** |
| 物理内存 | 105MB | **64MB** | -39% |
| Swap 占用 | 104MB | **37MB** | -64% |
| 代理响应 | 超时 | **0.84 秒** | ✅ |

### 持久化

订阅更新会覆盖 `config.yaml`。需要同时修改订阅源：

```sh
# 订阅源文件
sed -i 's|^    geoip: true|    geoip: false|' /etc/storage/app_20.sh
/sbin/mtd_storage.sh save
```

---

## 优化 2：主题包持久化

### 问题

固件把主题包下载到 `/opt/share/www/custom/`（5.9MB），但 `/opt` 是 tmpfs，每次重启都要重新下载。

日志表现为卡在：

```
【主题界面】: 主题风格包下载 1
```

（之后没有日志，因为脚本后面没有 logger 语句）

### 解决

把 `/opt/share` 也 bind mount 到 U 盘：

```sh
mkdir -p /media/opt/share
cp -a /opt/share/www /media/opt/share/
mount -o bind /media/opt/share /opt/share
```

然后加进启动脚本的 bind mount 列表：

```sh
for d in bin lib sbin usr var share; do
    mkdir -p /opt/$d
    mountpoint -q /opt/$d || mount -o bind $ENTWARE_MNT/$d /opt/$d
done
```

### 结果

重启后 `logread | grep 主题` 无输出，说明直接用了缓存。

---

## 优化 3：swap 启用

### 问题

128MB 内存跑 nginx + clash 后只剩 35MB，容易 OOM。

### 解决

在 U 盘上创建 128MB swap 文件：

```sh
dd if=/dev/zero of=/media/Data/swapfile bs=1M count=128
chmod 600 /media/Data/swapfile
/sbin/mkswap /media/Data/swapfile
/sbin/swapon /media/Data/swapfile
```

加进启动脚本（注意用绝对路径，脚本环境没设 PATH）：

```sh
SWAPFILE=$DATA_MNT/swapfile
if [ ! -f "$SWAPFILE" ]; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=128 2>/dev/null
    chmod 600 "$SWAPFILE"
    /sbin/mkswap "$SWAPFILE" >/dev/null 2>&1
fi
if [ $(wc -l < /proc/swaps) -le 1 ]; then
    /sbin/swapon "$SWAPFILE" 2>/dev/null
fi
```

### 踩过的坑

**坑 1：`swapon: not found`**

启动脚本没设 PATH，`swapon` 在 `/sbin` 里找不到。必须用 `/sbin/swapon`。

**坑 2：僵尸 swap 条目**

U 盘掉线时 swap 文件消失，但内核还记着 `/swapfile` 这个路径。重新挂载后无法再 `swapon`：

```
swapon: /media/Data/swapfile: Operation not permitted
```

只能重启清除。所以脚本里用 `wc -l < /proc/swaps` 判断是否有任何 swap，而不是检查特定路径。

### 效果

| | 优化前 | 优化后 |
|---|---|---|
| 物理可用 | 35MB | 60MB |
| Swap 可用 | 0 | 128MB |
| 合计 | 35MB | 188MB |

---

## 优化 4：守护进程 + UUID 识别

### 问题

U 盘在启动时供电不足，被内核下线：

```
usb 1-1: reset high-speed USB device number 2    (反复 5 次)
scsi 0:0:0:0: Device offlined - not ready after error recovery
```

后果：所有服务起不来，clash 内核文件损坏，需要重新下载 9.6MB。

### 解决

1. **守护进程**：持续轮询，U 盘回来后自动恢复
2. **UUID 识别**：设备名会从 `sda` 变 `sdb`，必须用 UUID

```sh
OPT_UUID=6637de50-514f-4270-9309-5edc2f3d388b
DATA_UUID=aab01a63-4fc6-4026-b709-ec16c4e596e2

find_dev() {
    for d in /dev/sd[a-z][0-9]; do
        [ -b "$d" ] || continue
        uuid=$(/sbin/blkid -s UUID -o value "$d" 2>/dev/null)
        [ "$uuid" = "$1" ] && echo "$d" && return 0
    done
    return 1
}
```

3. **幂等启动**：`remember-me-start.sh` 可以重复执行，已挂载的跳过

### 踩过的坑

**坑 1：`nohup ... &` 在 SSH 会话结束时被杀**

需要用 `setsid`（但路由器没有）或确保进程完全脱离终端。

**坑 2：clash 多实例**

`pidof clash` 在进程冲突时会误判，导致守护进程重复启动。改成进程计数：

```sh
clash_count=$(pgrep -f "clash -d" 2>/dev/null | wc -l)
if [ "$clash_count" -eq 0 ]; then
    # 启动
elif [ "$clash_count" -gt 1 ]; then
    # 清理多余
fi
```

---

## 内存占用参考

| 组件 | 内存 |
|---|---|
| 系统基础 | ~19MB |
| nginx (2 worker) | ~10MB |
| clash (优化后) | ~25MB |
| 监控脚本 | ~2MB |
| **合计** | **~56MB** |
| 剩余 | ~67MB |

## 性能基准

| 项目 | 数值 |
|---|---|
| U 盘顺序读写 | ~17-19 MB/s |
| 代理吞吐（trojan/AES） | ~20-40 Mbps |
| nginx 静态文件 | 受限于 U 盘 IO |
| clash 启动 | 0.56 秒 |

---

## 优化 5：clash 配置持久化，跳过固件生成

### 问题

冷复位后 clash 恢复要等 3 分钟：

```
[11:24:06] clash 配置未就绪，等待固件生成 (1/6)
[11:24:36] clash 配置未就绪，等待固件生成 (2/6)
...
[11:25:07] 已从 U 盘恢复 MMDB
[11:25:37] 已重新应用 geoip 优化
```

固件生成 `config.yaml` 需要下载订阅、用 yq 改写配置，在单核 CPU 上要 1-2 分钟。

### 方案

把**已生成的配置**存到 U 盘当模板，启动时直接复制：

```sh
# 保存当前配置作为模板
cp /opt/app/clash/config/config.yaml \
   /media/opt/app/clash/config/config.yaml.persist
```

守护进程优先用模板：

```sh
CLASH_TPL=/media/opt/app/clash/config/config.yaml.persist

if [ ! -s "$CLASH_CFG" ] || ! grep -q "^proxies:" "$CLASH_CFG" 2>/dev/null; then
    if [ -s "$CLASH_TPL" ]; then
        cp -f "$CLASH_TPL" "$CLASH_CFG"
        log "已从 U 盘模板恢复 clash 配置"
    else
        # 没模板才等固件生成
        ...
    fi
fi
```

### 为什么不用订阅源 `/etc/storage/app_20.sh`

订阅源缺少路由器需要的配置，固件会用 `yq` 改写：

| 配置项 | 订阅源 | 路由器需要 |
|---|---|---|
| `allow-lan` | `false` | `true` |
| `mixed-port` | 无 | `7893` |
| `external-controller` | `127.0.0.1:9090` | `192.168.123.1:27428` |
| `log-level` | `silent` | `info` |

所以必须用**已生成的配置**（固件改写后的），不能用原始订阅。

### 踩过的坑

**坑 1：clash 启动太快，读到空配置**

配置恢复和 clash 启动有竞态。加 `sync` + `sleep 2`：

```sh
sync
sleep 2
nohup /opt/bin/clash -d "$CLASH_DIR" >/tmp/clash.log 2>&1 < /dev/null &
```

**坑 2：启动前必须再检查一次配置**

即使在恢复逻辑之后，配置仍可能被固件的并发操作删掉。启动前再确认：

```sh
if ! grep -q "^proxies:" "$CLASH_CFG" 2>/dev/null; then
    log "配置在启动前丢失，跳过本轮"
else
    # 启动 clash
fi
```

### 结果

| 指标 | 优化前 | 优化后 |
|---|---|---|
| 冷复位后 clash 可用 | ~3 分钟 | **~45 秒** |
| 依赖固件生成配置 | 是 | 否（有模板时） |
| 订阅更新 | 自动 | 需手动触发 |

**代价**：订阅不会自动更新。需要更新时在后台点「更新订阅」，或者删除模板让固件重新生成。

### 坑 3：配置存在但内容错误

**现象**

重启后代理正常（7893 通），但面板 27428 不监听。检查配置：

```sh
$ grep external-controller /opt/app/clash/config/config.yaml
external-controller: '127.0.0.1:9090'    ← 订阅源的原始值
```

**原因**

守护进程只检查「配置文件是否存在」，但固件可能在重启前用原始订阅覆盖了它。
文件存在、`proxies:` 段也在，但 `external-controller`、`allow-lan`、`mixed-port` 都是订阅源的默认值。

**修复**

校验关键字段，不匹配就恢复模板：

```sh
cfg_bad=0
[ ! -s "$CLASH_CFG" ] && cfg_bad=1
grep -q "^proxies:" "$CLASH_CFG" 2>/dev/null || cfg_bad=1
grep -q "^external-controller: 192.168.123.1" "$CLASH_CFG" 2>/dev/null || cfg_bad=1
grep -q "^allow-lan: true" "$CLASH_CFG" 2>/dev/null || cfg_bad=1
grep -q "^mixed-port: 7893" "$CLASH_CFG" 2>/dev/null || cfg_bad=1

if [ "$cfg_bad" = "1" ]; then
    cp -f "$CLASH_TPL" "$CLASH_CFG"
    log "clash 配置无效或缺失，已从 U 盘模板恢复"
fi
```

这样即使固件覆盖了配置，守护进程下一轮（30 秒内）就会修正。
