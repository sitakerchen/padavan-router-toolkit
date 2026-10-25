# 架构与挂载原理

## 整体布局

```
┌─────────────────────────────────────────────────────────┐
│ 路由器 RT-AC51U (128MB RAM, MT7620A)                     │
│                                                          │
│  /etc/storage (flash 704KB, 重启保留)                    │
│  ├── started_script.sh        开机钩子                   │
│  ├── remember-me-start.sh     服务启动                   │
│  ├── remember-me-watchdog.sh  守护进程                   │
│  ├── monitor-gen.sh           监控数据生成               │
│  ├── monitor-loop.sh          监控循环                   │
│  └── ssh/authorized_keys      SSH 公钥                   │
│                                                          │
│  /opt (tmpfs 61MB, 重启清空)                             │
│  ├── bin  ──bind──> /media/opt/bin   (Entware 二进制)    │
│  ├── lib  ──bind──> /media/opt/lib                       │
│  ├── sbin ──bind──> /media/opt/sbin  (nginx, clash)      │
│  ├── usr  ──bind──> /media/opt/usr                       │
│  ├── var  ──bind──> /media/opt/var   (opkg 数据库)       │
│  ├── share──bind──> /media/opt/share (主题包 5.9MB)      │
│  └── etc          (每次启动从 U 盘复制配置)              │
│                                                          │
│  /media/opt  ← /dev/sda1 (ext4, 2GB)                     │
│  /media/Data ← /dev/sda2 (ext4, 56GB)                    │
│      └── www/remember-me/  静态站点                      │
│      └── swapfile          128MB swap                    │
└─────────────────────────────────────────────────────────┘
```

## U 盘分区

原厂 U 盘是 exFAT，不支持 Linux 权限和符号链接，必须重新格式化。

```sh
# 1. 卸载
umount /media/Data

# 2. 重新分区（MBR，两个主分区）
parted -s /dev/sda mklabel msdos
parted -s -a optimal /dev/sda mkpart primary ext4 1MiB 2049MiB
parted -s -a optimal /dev/sda mkpart primary ext4 2049MiB 100%

# 3. 让内核重新读取分区表
#    极2 上 blockdev --rereadpt 不可用，需要断电重上电
hub-ctrl -b 1 -d 1 -P 1 -p 0 && sleep 5 && hub-ctrl -b 1 -d 1 -P 1 -p 1

# 4. 格式化
modprobe ext4
mkfs.ext4 -L opt  -F /dev/sda1
mkfs.ext4 -L Data -F /dev/sda2
```

分区布局：

| 分区 | 大小 | 标签 | 用途 |
|---|---|---|---|
| sda1 | 2GB | opt | Entware 系统 |
| sda2 | 56GB | Data | 站点文件 + swap |

## 挂载顺序

启动时按以下顺序执行（`remember-me-start.sh`）：

1. **等待设备**：按 UUID 查找分区，最多 20 秒
2. **清理固件挂载**：
   - 卸载 `/www/*.asp` 上的 bind mount
   - 卸载 `/media/AiDisk_*`
   - 卸载 `/opt` 及其子目录
3. **恢复 `/opt` 为 tmpfs**：卸载后 `/opt` 会变成只读根目录，必须重新挂载
4. **挂载分区**到 `/media/opt` 和 `/media/Data`
5. **bind mount 子目录**到 `/opt`
6. **复制配置**：nginx、opkg、passwd/group
7. **启动 nginx**
8. **启用 swap**
9. **启动监控**

## 为什么不能直接挂 `/opt`

Padavan 的 `/opt` 是 tmpfs，固件在里面放了运行时文件。直接挂 ext4 分区会导致：

- `/opt/etc/profile` 被覆盖 → SSH 登录 shell 初始化失败
- 现象：**SSH 密码认证成功，但任何命令都立即退出（exit 1）**
- 必须重启路由器才能恢复

正确做法是保留 `/opt` 为 tmpfs，只 bind mount 需要的子目录。

## 固件 automount 的坑

Padavan 的 `/sbin/automount.sh` 会自动挂载 U 盘，但它有两个问题：

1. **会把分区挂到 `/opt`**（如果 `/opt` 是空的）
2. **会把 `/www/*.asp` bind mount 到 U 盘上**（为了支持扩展功能）

我们的启动脚本必须先清理这些：

```sh
for m in $(mount | awk '$3 ~ /^\/www\// {print $3}'); do
    umount "$m" 2>/dev/null
done
for m in $(mount | awk '$3 ~ /^\/media\/AiDisk/ {print $3}'); do
    umount "$m" 2>/dev/null
done
for d in bin lib sbin usr var share; do
    mount | grep -q " on /opt/$d " && umount -l /opt/$d 2>/dev/null
done
if mountpoint -q /opt; then
    umount -l /opt 2>/dev/null
fi
mountpoint -q /opt || mount -t tmpfs -o size=62464k tmpfs /opt
```

## 守护进程设计

`remember-me-watchdog.sh` 是一个无限循环，每 10-30 秒检查一次：

```
┌──────────────────────────────────────────┐
│  disk_ready() ?                          │
│    ├── 是 → ensure_services() → sleep 30 │
│    └── 否 → 按 UUID 找设备               │
│              ├── 找到 → 清理挂载 + 重挂   │
│              └── 没找到 → sleep 10       │
└──────────────────────────────────────────┘
```

关键点：

- **按 UUID 识别设备**，不受 `sda`/`sdb` 变化影响
- **幂等启动**：`remember-me-start.sh` 可以重复执行
- **不依赖 U 盘**：守护进程本身跑在内存里
- **自动清理重复进程**：clash 多实例检测

## 开机启动链路

```
路由器启动
  └── /etc/storage/started_script.sh
        ├── stop_ftpsamba
        ├── automount.sh（固件自动挂载，会产生错误挂载）
        ├── run_ftpsamba
        ├── script_script.sh
        └── [我们追加的]
              ├── remember-me-start.sh &
              └── remember-me-watchdog.sh &
```

## 持久化机制

`/etc/storage` 是 flash 分区，修改后必须写入：

```sh
/sbin/mtd_storage.sh save
```

**注意**：写入失败时（`Input/output error`）会导致 flash 数据损坏，重启后 `/etc/storage` 被回滚到上次成功保存的状态。我们的脚本会全部丢失。

建议：
- 修改后立即 `save`
- 保存后用 `ls -la /etc/storage/` 确认文件还在
- 重要配置在 U 盘上留一份备份

## 在路由器后台添加自定义菜单项

Padavan 后台的左侧菜单由 `/etc/storage/www_sh/` 目录下的脚本动态注册。

### 机制

1. `menu_title.sh` 里的 `menu_title_all` 变量列出所有允许的菜单名
2. `run_www_sh()` 遍历 `menuN_titleM` nvram 槽位
3. 如果槽位的值在 `menu_title_all` 里，且 `www_sh/<值>` 文件存在，就执行它
4. 脚本里的 `nvram set tablink<编号>=<页面>` 注册链接

**槽位编号规则**：`menu{列}_{行}` → `tablink{列}{行}`
例如 `menu12_title4` → `tablink124`

### 添加步骤

**1. 准备页面**

固件的 `/www` 是只读分区，需要把自定义页面 bind mount 上去：

```sh
mkdir -p /media/opt/app/status
# 把页面放到 /media/opt/app/status/Advanced_Extensions_status.asp
umount /www/Advanced_Extensions_app30.asp 2>/dev/null
mount --bind /media/opt/app/status/Advanced_Extensions_status.asp \
              /www/Advanced_Extensions_app30.asp
```

**2. 创建菜单脚本** `/etc/storage/www_sh/系统状态`

```bash
#!/bin/bash
source /etc/storage/script/init.sh

link="Advanced_Extensions_app30.asp"

if [ "$1"x = "stop"x ] ; then
    exit
fi

if [ "$1" != "del" ] ; then
    eval 'nvram set tablink'$1'='$link';'
    nvram set status_L2="$(($3 + 10))"
    nvram set status_L3="$2"
fi

if [ -f /media/opt/app/status/Advanced_Extensions_status.asp ]; then
    umount /www/Advanced_Extensions_app30.asp 2>/dev/null
    mount --bind /media/opt/app/status/Advanced_Extensions_status.asp \
                  /www/Advanced_Extensions_app30.asp 2>/dev/null
fi
```

**3. 把菜单名加进 `menu_title_all`**

编辑 `/etc/storage/www_sh/menu_title.sh`，在 `menu_title5` 末尾追加：

```sh
menu_title5="... clash 系统状态"
```

**4. 设置 nvram 槽位并注册**

```sh
nvram set menu12_title4="系统状态"
/etc/storage/www_sh/系统状态 124 12 4
```

**5. 持久化**

```sh
/sbin/mtd_storage.sh save
```

启动脚本末尾已包含步骤 4，重启自动恢复。

### 踩过的坑

**坑 1：`menu_title.sh re` 会清空所有槽位**

`re` 参数会先执行 `title_init`（把所有 `menuN_titleM` 设为空），再重新填充。
如果手动设置了槽位后执行 `re`，设置会丢失。

用 `check` 代替，或者直接执行菜单脚本。

**坑 2：`check_www_sh` 会删除未注册的菜单文件**

```sh
for file in `ls -L /etc/storage/www_sh/`
do
if [ -z "$(echo "$menu_title_set" | grep "$file")" ] ; then
    /etc/storage/www_sh/$file stop
fi
done
```

所以必须先在 nvram 里注册槽位，脚本才不会被清理。
