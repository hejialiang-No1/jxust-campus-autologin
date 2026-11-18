#!/bin/bash
# 一键部署：把脚本装到 ~/.local/bin、生成配置、加载 launchd 守护
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/bin/campus-autologin"
CONF_DIR="$HOME/.config/campus-autologin"

mkdir -p "$HOME/.local/bin" "$CONF_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$SRC/campus-autologin" "$DEST"
chmod +x "$DEST"
[ -f "$CONF_DIR/config.env" ] || cp "$SRC/config.env" "$CONF_DIR/config.env"
# 老配置补新增键：只追加缺失项，绝不改动用户已填的学号 / 接口 / 判据
for kv in 'CHECK_INTERVAL=30' 'FAST_WAIT_SEC=15' 'FAST_POLL_SEC=2' 'LOG_MAX_LINES=3000' 'CLOSE_BROWSER_TABS=0'; do
  k="${kv%%=*}"
  grep -q "^$k=" "$CONF_DIR/config.env" || printf '%s\n' "$kv" >> "$CONF_DIR/config.env"
done
chmod 700 "$CONF_DIR" 2>/dev/null
chmod 600 "$CONF_DIR/config.env" 2>/dev/null

bash -n "$DEST" || { printf '脚本语法检查失败\n'; exit 1; }

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) printf '提示: 把下面这行加进 ~/.zshrc 就能直接敲 campus-autologin：\n  export PATH="$HOME/.local/bin:$PATH"\n\n' ;;
esac

"$DEST" install
printf '\n部署完成。开机自启已配置（登录后自动运行）。接下来：\n'
printf '  campus-autologin autostart  自检并修复开机自启（重启后想确认就跑它）\n'
printf '  campus-autologin status     查看状态\n'
printf '  campus-autologin set-cred   更换账号密码（若已配置可跳过）\n'
printf '  campus-autologin close-popup  收掉已弹出的登录页窗口 / 浏览器标签页\n'
printf '  campus-autologin no-popup   查看弹窗抑制说明（macOS 27 老开关已失效）\n'
printf '  连校园网但未认证时: campus-autologin probe 可抓跳转与表单\n'
