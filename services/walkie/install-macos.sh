#!/usr/bin/env bash
# 装对讲服务(launchd 常驻)。骨架在 ../install-service.sh。
#
# ⚠ 端口写在这里,不在骨架里。两个服务抢同一个端口的话,后起的那个会
# 静默退出 —— launchctl list 里看得到,lsof 里没有,而"装好了"照常打印。
set -euo pipefail
exec "$(dirname "$0")/../install-service.sh" walkie 8787 "$@"
