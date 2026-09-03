#!/usr/bin/env bash
# 通用的服务安装脚本。两个服务各有一份一行的 wrapper 调它。
#
# 拆服务之前只有一个二进制,这个脚本里到处写死 walkie-server。现在
# 名字、端口、额外参数都从外面传 —— 复制一份改名字的话,两份迟早漂移,
# 而漂移的表现是"某个服务重装之后日志跑到另一个服务的文件里"。
set -euo pipefail

svc="${1:?用法: install-service.sh <服务名> <端口> [额外的 launchd 参数...]}"
port="${2:?端口不能省 —— 两个服务不能抢同一个}"
shift 2

cd "$(dirname "$0")/$svc"

label="com.folotoy.ai-passport.$svc-server"
support_dir="$HOME/Library/Application Support/FoloToy"
bin_dir="$support_dir/bin"
log_dir="$HOME/Library/Logs/FoloToy"
plist="$HOME/Library/LaunchAgents/$label.plist"
binary="$bin_dir/$svc-server"
uid="$(id -u)"


mkdir -p "$bin_dir" "$log_dir" "$(dirname "$plist")"
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    go build -o "$binary" .

tmp_plist="$(mktemp "${TMPDIR:-/tmp}/$svc-server-plist.XXXXXX")"
trap 'rm -f "$tmp_plist"' EXIT
cat >"$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>-i</string>
    <string>HOME=$HOME</string>
    <string>USER=$USER</string>
    <string>TMPDIR=${TMPDIR:-/tmp}</string>
    <string>PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <string>$binary</string>
    <string>-listen</string>
    <string>0.0.0.0:$port</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/$svc-server.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/$svc-server.err.log</string>
</dict>
</plist>
EOF

plutil -lint "$tmp_plist"
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
install -m 0644 "$tmp_plist" "$plist"
launchctl bootstrap "gui/$uid" "$plist"
launchctl enable "gui/$uid/$label"
launchctl kickstart -k "gui/$uid/$label"

echo "Installed $label"
echo "Health: http://127.0.0.1:$port/healthz"
