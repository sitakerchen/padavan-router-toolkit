# Padavan Router Toolkit

极路由2（RT-AC51U）刷 Padavan 老毛子固件后的实用配置与优化沉淀。

把一台 128MB 内存、单核 580MHz 的老路由器，改造成能跑静态站点、代理、监控的常驻小服务器。

## 硬件与固件

| 项目 | 规格 |
|---|---|
| 型号 | 极路由2 / RT-AC51U-GPIO-12-ji2-128M |
| SoC | MediaTek MT7620A，单核 580MHz（MIPS） |
| 内存 | 128MB（可用约 123MB） |
| Flash | 16MB（其中 `/etc/storage` 仅 704KB） |
| 固件 | Padavan (hiboy) `3.4.3.9-099_26-03-1` |
| 存储 | U 盘 58GB，分两个 ext4 分区 |

> 固件下载：<https://opt.cn2qq.com/padavan/>
> 对应文件：`RT-AC51U-GPIO-12-ji2-128M_3.4.3.9-099.trx`
> 注意 `3.4.3.9` 是华硕基线版本号，永远不变；实际新旧看内核编译时间或 `/etc/storage/Builds-*`。

## 这套配置解决了什么

| 问题 | 解法 | 效果 |
|---|---|---|
| 路由器自带 httpd 只能服务只读的 `/www` | Entware + nginx 监听 8080 | 可部署任意静态站点 |
| U 盘 exFAT 不支持 Linux 权限 | 重新分区为两个 ext4 | 支持符号链接、权限、swap |
| 固件 `automount.sh` 把分区挂到 `/opt` 导致 SSH 崩溃 | 只 bind mount 子目录，`/opt` 保持 tmpfs | SSH 稳定 |
| 重启后 U 盘掉线，服务全挂 | 守护进程按 UUID 轮询恢复 | 自动恢复 |
| 主题包每次重启重下 5MB | `/opt/share` 持久化到 U 盘 | 秒加载 |
| clash 启动要 87 秒、吃 105MB 内存 | 关掉 `fallback-filter.geoip` | **0.56 秒 / 64MB** |
| 内存不足 | 128MB swap 文件 | 防止 OOM |

## 目录结构

```
.
├── install/                    安装脚本
│   └── install.sh              一键部署到路由器
├── scripts/                    部署到 /etc/storage 的脚本
│   ├── remember-me-start.sh    服务启动（幂等，可重复执行）
│   ├── remember-me-watchdog.sh 守护进程（U 盘掉线自动恢复）
│   ├── monitor-gen.sh          生成 status.json
│   └── monitor-loop.sh         每 30 秒调用 monitor-gen
├── config/                     配置文件
│   ├── nginx-remember-me.conf  nginx 站点配置
│   ├── opkg.conf               Entware 软件源
│   └── started_script.sh       开机启动钩子（参考）
├── www/
│   └── status.html             系统状态监控页
└── docs/
    ├── ARCHITECTURE.md         架构与挂载原理
    ├── TROUBLESHOOTING.md      故障排查
    └── OPTIMIZATION.md         性能优化记录
```

## 快速开始

### 前置条件

1. 路由器已刷 Padavan 固件，开启 SSH
2. U 盘已格式化为两个 ext4 分区（见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#u-盘分区)）
3. 本机已安装 `sshpass`（`brew install sshpass`）

### 安装

```bash
# 修改 install/install.sh 顶部的配置（IP、密码、UUID）
./install/install.sh
```

脚本会：

1. 检测 U 盘分区并挂载
2. 安装 Entware（opkg）
3. 安装 nginx
4. 部署脚本和配置到 `/etc/storage`
5. 创建 128MB swap
6. 配置开机自启
7. 写入 flash 持久化

### 验证

```bash
curl http://192.168.123.1:8080/status.json
```

## 服务清单

| 服务 | 端口 | 说明 |
|---|---|---|
| 路由器后台 | 80 | `http://192.168.123.1` |
| 静态站点 | 8080 | nginx |
| 状态监控 | 8080/status.html | 内存/Swap/磁盘/服务 |
| Clash 代理 | 7893 | HTTP/SOCKS5 混合 |
| Clash 面板 | 27428 | Web UI |
| SSH | 22 | dropbear |

## 关键设计决策

### 为什么 `/opt` 保持 tmpfs

Padavan 的 `/opt` 原本是 tmpfs，里面放固件运行时文件。如果直接把 ext4 分区挂上去：

- 覆盖固件依赖的 `/opt/etc/profile`
- **SSH 登录后命令立即退出（exit 1）**
- 必须重启才能恢复

正确做法是只 bind mount 需要的子目录：

```sh
for d in bin lib sbin usr var share; do
    mount -o bind /media/opt/$d /opt/$d
done
```

### 为什么用 UUID 而不是 `/dev/sda1`

U 盘掉线重连后，设备名会从 `sda` 变成 `sdb`。用 UUID 才稳定：

```sh
find_dev() {
    for d in /dev/sd[a-z][0-9]; do
        [ -b "$d" ] || continue
        uuid=$(blkid -s UUID -o value "$d" 2>/dev/null)
        [ "$uuid" = "$1" ] && echo "$d" && return 0
    done
    return 1
}
```

### 为什么关掉 `fallback-filter.geoip`

`geoip: true` 会让 mihomo 加载 GeoSite 数据库，展开成 **13.7 万条内存记录**：

```
Finished initial GeoSite rule cn => records: 110448
Finished initial GeoSite rule geolocation-!cn => records: 27420
```

在 128MB 设备上，这会导致 87 秒启动 + 大量 swap。

关掉后 `GEOIP,CN` 规则仍然可用（用的是 403KB 的 GeoIP 库，不是 4.1MB 的 GeoSite）。

详见 [docs/OPTIMIZATION.md](docs/OPTIMIZATION.md)。

## 已知限制

| 限制 | 说明 |
|---|---|
| CPU 弱 | 单核 580MHz，代理吞吐约 20-40Mbps |
| 内存小 | 跑 nginx + clash 后剩约 60MB |
| USB 供电弱 | 极2 的 USB 口带 USB 3.0 盘容易启动失败，需物理拔插 |
| `/etc/storage` 仅 704KB | 只能放脚本，不能放二进制 |
| 内核 3.4 | 不支持 Docker、新版 iptables 特性 |

## 参考

- [Padavan 固件下载](https://opt.cn2qq.com/padavan/)
- [Entware](https://entware.net/)
- [mihomo (Clash Meta)](https://github.com/MetaCubeX/mihomo)

## License

MIT
