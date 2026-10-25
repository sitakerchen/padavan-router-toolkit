#!/bin/bash
# 系统状态菜单项
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

# 把状态页面 bind mount 到 /www
if [ -f /media/opt/app/status/Advanced_Extensions_status.asp ]; then
    umount /www/Advanced_Extensions_app30.asp 2>/dev/null
    mount --bind /media/opt/app/status/Advanced_Extensions_status.asp /www/Advanced_Extensions_app30.asp 2>/dev/null
fi
