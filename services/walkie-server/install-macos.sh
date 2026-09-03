#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

label="com.folotoy.ai-passport.walkie-server"
support_dir="$HOME/Library/Application Support/FoloToy"
bin_dir="$support_dir/bin"
log_dir="$HOME/Library/Logs/FoloToy"
plist="$HOME/Library/LaunchAgents/$label.plist"
binary="$bin_dir/walkie-server"
uid="$(id -u)"

mkdir -p "$bin_dir" "$log_dir" "$(dirname "$plist")"
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    go build -o "$binary" .

tmp_plist="$(mktemp "${TMPDIR:-/tmp}/walkie-server-plist.XXXXXX")"
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
    <string>0.0.0.0:8787</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/walkie-server.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/walkie-server.err.log</string>
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
echo "Health: http://127.0.0.1:8787/healthz"
