# 故障排查

## SSH 能登录但命令立即退出（exit 1）

**现象**

```
$ ssh admin@192.168.123.1 'echo hi'
# 认证成功，但无输出，退出码 1
```

**原因**

`/opt` 被错误挂载覆盖了。Padavan 的登录 shell 会读 `/opt/etc/profile`，覆盖后初始化失败。

**诊断**

```sh
mount | grep " on /opt "
# 如果显示 /dev/sda2 on /opt type ext4 ← 就是这个问题
```

**修复**

```sh
umount -l /opt
mount -t tmpfs -o size=62464k tmpfs /opt
```

如果 SSH 完全无法执行命令，只能重启路由器。

---

## U 盘读不出来（No medium found）

**现象**

```
$ dd if=/dev/sdb bs=512 count=1
dd: can't open '/dev/sdb': No medium found
```

dmesg 显示：

```
usb 1-1: reset high-speed USB device number 2
usb 1-1: reset high-speed USB device number 2
scsi 0:0:0:0: Device offlined - not ready after error recovery
```

**原因**

极2 的 USB 口供电偏弱。SanDisk Cruzer Glide 3.0 是 USB 3.0 盘，启动瞬间电流需求大，握手失败。

**修复**

**物理拔插 U 盘**（等 5 秒再插回）。

`hub-ctrl` 断电重上电**无效** —— 实测多次都无法恢复，必须物理操作。

**长期方案**

- 换 USB 2.0 盘（功耗低得多）
- 或用带外接电源的 USB Hub

---

## 8080 端口不通

**诊断**

```sh
cat /tmp/remember-me.log
ps | grep nginx
mount | grep -E "media/(opt|Data)"
```

**常见原因**

| 日志内容 | 原因 | 修复 |
|---|---|---|
| `U 盘未就绪` | U 盘没挂载 | 检查 `cat /proc/partitions \| grep sd` |
| `分区挂载失败` | 文件系统损坏 | `fsck.ext4 -y /dev/sda2` |
| `nginx 或配置缺失` | 配置没复制 | 检查 `/media/opt/etc/nginx/remember-me.conf` |
| 无日志 | 脚本没执行 | 检查 `/etc/storage/started_script.sh` 末尾 |

**手动恢复**

```sh
/etc/storage/remember-me-start.sh
```

---

## opkg 报 Couldn't stat /opt/etc/opkg.conf

**原因**

`/opt/etc` 是 tmpfs，重启后清空。

**修复**

```sh
cp /media/opt/etc/opkg.conf /opt/etc/opkg.conf
mkdir -p /opt/var/lib/opkg /opt/usr/bin /opt/usr/sbin /opt/usr/lib /opt/usr/share
```

启动脚本已包含这一步，如果还报错说明脚本没执行。

---

## 主题包每次重启都重新下载

**诊断**

```sh
mount | grep /opt/share
# 应该显示 /dev/sda1 on /opt/share type ext4
```

**修复**

```sh
mkdir -p /media/opt/share
cp -a /opt/share/www /media/opt/share/
mount -o bind /media/opt/share /opt/share
```

并确认启动脚本的 bind mount 列表包含 `share`。

---

## clash 启动很慢 / 内存爆满

**诊断**

```sh
grep "Initial configuration complete" /tmp/clash.log
# 如果 total time 是 80000+ ms，就是 GeoSite 问题
```

**修复**

```sh
sed -i 's|^    geoip: true|    geoip: false|' /opt/app/clash/config/config.yaml
sed -i 's|^    geoip: true|    geoip: false|' /etc/storage/app_20.sh
```

详见 [OPTIMIZATION.md](OPTIMIZATION.md#优化-1clash-启动时间从-87-秒降到-056-秒)。

---

## clash 端口被占用（address already in use）

**现象**

```
level=error msg="Start Mixed(http+socks) server error: listen tcp :7893: bind: address already in use"
```

**原因**

多个 clash 实例同时运行。

**诊断**

```sh
ps | grep "clash -d"
```

**修复**

```sh
pkill -9 -f "clash -d"
pkill -9 -f "Sh10_clash"
sleep 5
nohup /opt/bin/clash -d /opt/app/clash/config >/tmp/clash.log 2>&1 &
```

---

## /etc/storage 里的脚本重启后消失

**现象**

重启后 `/etc/storage/remember-me-start.sh` 等文件不见了，`started_script.sh` 也回到原始状态。

**原因**

`mtd_storage.sh save` 写入 flash 时失败（`Input/output error`），导致数据损坏被回滚。

**预防**

```sh
# 保存后立即验证
/sbin/mtd_storage.sh save
ls -la /etc/storage/remember-me-*.sh
```

**恢复**

重新部署脚本（见 `install/install.sh`）。

---

## swap 启用失败（Operation not permitted）

**原因**

U 盘掉线时留下的僵尸 swap 条目，内核还记着旧路径 `/swapfile`。

**诊断**

```sh
cat /proc/swaps
# 如果显示 /swapfile 但该文件不存在，就是这个问题
```

**修复**

只能重启清除。脚本已改成用 `wc -l < /proc/swaps` 判断，避免重复 `swapon`。

---

## 内存一直很紧张

**查看真实可用内存**

```sh
free -m
```

关注 `Swap used`：

| Swap used | 含义 |
|---|---|
| 0 | 物理内存够用 |
| < 30MB | 轻微压力，正常 |
| > 60MB | 严重不足，考虑关服务 |

**注意**：`free` 显示的 `free` 列很低是正常的 —— Linux 会用空闲内存做文件缓存（`buff/cache`），随时可回收。

---

## 常用命令速查

```sh
# 服务状态
ps | grep -E "nginx|clash -d|monitor-loop|remember-me-watch"

# 启动日志
cat /tmp/remember-me.log

# clash 日志
cat /tmp/clash.log

# 内存
free -m

# 挂载
mount | grep -E "sda|/opt"

# 端口
netstat -ln | grep -E "8080|7893|27428"

# 重启 nginx
kill $(cat /opt/var/run/nginx-remember-me.pid)
/etc/storage/remember-me-start.sh

# 保存配置到 flash
/sbin/mtd_storage.sh save
```
