#!/bin/bash
# 双击运行：在终端.app 的登录会话里注册校园网自动认证守护
# WorkBuddy 会话里 launchctl bootstrap 会被系统拒绝，必须由本终端执行
CLI="$HOME/.local/bin/campus-autologin"
U=$(id -u)
L="com.hejialiang.campus-autologin"
P="$HOME/Library/LaunchAgents/$L.plist"
if [ ! -x "$CLI" ]; then
  echo "未找到 $CLI，请先运行 install.sh"
  echo "按回车键关闭..."
  read -r
  exit 1
fi

echo "===== 1/3 安装 / 更新开机自启守护 ====="
"$CLI" install
# 让新的 30 秒兜底周期立刻生效。先用临时测试 plist 探测本会话能否向
# launchd 注册：只有能注册才重载真实服务，避免把正常运行的自启弄丢。
PROBE="/tmp/cal-probe-$U.plist"
cat > "$PROBE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.hejialiang.cal-probe</string>
<key>ProgramArguments</key><array><string>/bin/echo</string><string>probe</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF
if launchctl bootstrap "gui/$U" "$PROBE" >/dev/null 2>&1; then
  launchctl bootout "gui/$U/com.hejialiang.cal-probe" >/dev/null 2>&1
  launchctl bootout "gui/$U/$L" >/dev/null 2>&1
  launchctl bootstrap "gui/$U" "$P" >/dev/null 2>&1 || launchctl load -w "$P" >/dev/null 2>&1
  if launchctl print "gui/$U/$L" >/dev/null 2>&1; then
    echo "守护已按新配置重载（每 30 秒兜底）"
  else
    echo "重载未成功；注销重登后系统会自动按新配置加载"
  fi
else
  echo "当前会话不允许重载 launchd（不影响已运行的守护）。"
  echo "新周期在注销重新登录后生效；连 Wi-Fi 的即时触发现在就已生效。"
fi
rm -f "$PROBE"
echo

echo "===== 2/3 收掉连 Wi-Fi 弹出的登录页 ====="
"$CLI" no-popup
echo
"$CLI" close-popup
echo
echo "macOS 27 已无法彻底禁止系统探测，登录页可能在认证完成前那一两秒闪出来；"
echo "现在认证成功后守护会自动把它收起，不用你管。"
echo "浏览器里的登录页标签页：上面这一步首次会弹自动化授权框，点「好」即可；"
echo "之后把 ~/.config/campus-autologin/config.env 里 CLOSE_BROWSER_TABS 改成 1，"
echo "标签页也会自动收。再把浏览器主页设成 HTTPS、关掉「启动时恢复上次标签页」，"
echo "认证前那两秒就不会有 HTTP 请求被校园网 302 成登录页了。"
echo

echo "===== 3/3 开机自启自检 + 当前状态 ====="
"$CLI" autostart
echo
"$CLI" status
echo
echo "===== 常用命令 ====="
echo "  $CLI autostart   自检并修复开机自启（重启后想确认就跑它）"
echo "  $CLI status      查看状态"
echo "  $CLI log         查看认证日志"
echo "  $CLI set-cred    更换账号密码（密码存钥匙串）"
echo "  $CLI close-popup 收掉已弹出的登录页窗口 / 浏览器标签页"
echo "  $CLI no-popup    查看弹窗抑制说明"
echo "  $CLI popup-on    恢复系统老开关默认设置"
echo
echo "按回车键关闭窗口..."
read -r
