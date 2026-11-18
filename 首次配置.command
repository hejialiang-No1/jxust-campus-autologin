#!/bin/bash
# 双击运行：首次填入一卡通号 / 密码 / 网络服务商，装好开机自启守护。
# 之后开机、Wi-Fi 断开重连都会自动认证，不用再输任何东西。
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=en_US.UTF-8

SRC="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$HOME/.config/campus-autologin"
CONF="$CONF_DIR/config.env"
CLI="$HOME/.local/bin/campus-autologin"
KC_SERVICE="campus-autologin"
# 离线自检钩子：CAL_DRY_RUN=1 只写配置、不装守护；CAL_SECURITY_CMD 可替换钥匙串命令
SECURITY_CMD="${CAL_SECURITY_CMD:-security}"
DRY_RUN="${CAL_DRY_RUN:-0}"

echo "====== 江西理工大学 JXUST-WLAN 校园网自动认证 · 首次配置 (macOS) ======"
echo

mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR" 2>/dev/null
if [ ! -f "$CONF" ]; then
  cp "$SRC/config.env" "$CONF"
  chmod 600 "$CONF"
fi

# 只取配置里的键值，不 source 整个文件（避免注释/特殊字符被当命令执行）
get_kv() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1 | sed -e 's/^"//' -e 's/"$//'; }
set_kv() {
  local k="$1" v="$2" esc
  esc=$(printf '%s' "$v" | sed -e 's/[\/&|\\]/\\&/g')
  if grep -q "^$k=" "$CONF"; then
    sed -i '' "s|^$k=.*|$k=\"$esc\"|" "$CONF"
  else
    printf '%s="%s"\n' "$k" "$esc" >> "$CONF"
  fi
}

OLD_USER=$(get_kv USERNAME)
OLD_SUFFIX=$(get_kv ACCOUNT_SUFFIX)
OLD_PASS=$("$SECURITY_CMD" find-generic-password -s "$KC_SERVICE" -w 2>/dev/null)

if [ -n "$OLD_USER" ] && [ -n "$OLD_PASS" ]; then
  echo "检测到已保存的账号: ${OLD_USER}${OLD_SUFFIX}（密码在钥匙串，不会显示）"
  printf '直接回车保持不变；输入 r 重新填写: '
  IFS= read -r redo
  if [ "$redo" != "r" ] && [ "$redo" != "R" ]; then
    echo "保持原有账号密码，只重新检查自启与弹窗设置。"
    SKIP_CRED=1
  fi
fi

if [ -z "$SKIP_CRED" ]; then
  echo
  printf '一卡通号 [%s]: ' "${OLD_USER:-}"
  IFS= read -r acct
  [ -z "$acct" ] && acct="$OLD_USER"
  while [ -z "$acct" ]; do printf '账号不能为空，请重新输入: '; IFS= read -r acct; done

  if [ -n "$OLD_PASS" ]; then
    printf '一卡通密码（输入不回显，回车保持原密码）: '
  else
    printf '一卡通密码（输入不回显）: '
  fi
  IFS= read -rs pass; printf '\n'
  if [ -z "$pass" ]; then
    pass="$OLD_PASS"
  fi
  if [ -z "$pass" ]; then echo '密码不能为空，已退出。'; exit 1; fi

  echo
  echo '网络服务商（决定账号后缀，密码不变）：'
  echo '  1) 中国移动   @cmcc'
  echo '  2) 中国电信   @telecom'
  echo '  3) 中国联通   @unicom'
  echo '  4) 校园网/无后缀'
  printf '选择 1-4 [当前 %s，回车保持]: ' "${OLD_SUFFIX:-无后缀}"
  IFS= read -r choice
  case "$choice" in
    1) suffix='@cmcc' ;;
    2) suffix='@telecom' ;;
    3) suffix='@unicom' ;;
    4) suffix='' ;;
    *) suffix="$OLD_SUFFIX" ;;
  esac

  set_kv USERNAME "$acct"
  set_kv ACCOUNT_SUFFIX "$suffix"
  "$SECURITY_CMD" add-generic-password -U -a "$acct" -s "$KC_SERVICE" -w "$pass" >/dev/null 2>&1 || {
    echo '写入钥匙串失败：请先解锁钥匙串（或重启后再试）。'; exit 1; }
  chmod 600 "$CONF"
  echo
  echo "  [OK] 账号 ${acct}${suffix} 已保存，密码已存入 macOS 钥匙串（不落盘明文）"
  unset pass OLD_PASS
fi

# 授权完成后打开标签页自动清理，认证成功时守护会顺手收掉被 302 出来的登录页
set_kv CLOSE_BROWSER_TABS 1

if [ "$DRY_RUN" = "1" ]; then
  echo
  echo '[自检模式 CAL_DRY_RUN=1] 配置已写入，跳过部署 / 守护 / 认证，不触碰真实钥匙串与 launchd。'
  printf '按回车键关闭窗口...'
  IFS= read -r _
  exit 0
fi

echo
echo '====== 1/4 部署脚本 + 注册开机自启守护 ======'
bash "$SRC/install.sh" || { echo '部署失败'; exit 1; }

echo
echo '====== 2/4 关闭连 Wi-Fi 自动弹出的登录网页 ======'
# 先手动跑一次，触发 macOS 自动化授权（弹框点「好」），守护以后才能自动关浏览器标签页
"$CLI" close-popup
echo '  [OK] 认证成功后会自动收起系统登录页窗口 + 浏览器里的 Portal 标签页'

echo
echo '====== 3/4 开机自启自检 + 立即认证一次 ======'
"$CLI" autostart
echo
"$CLI" login
echo
echo '====== 4/4 当前状态 ======'
"$CLI" status

echo
echo '配置完成。以后开机登录 macOS、Wi-Fi 断开重连、网络掉线都会自动认证。'
echo '想改账号/运营商/密码：重新双击本文件。'
echo "日志: ~/Library/Logs/campus-autologin.log"
echo
echo '提示：浏览器主页设成 HTTPS、关掉「启动时恢复上次标签页」，'
echo '认证前那一两秒就不会有 HTTP 请求被校园网 302 成登录页。'
echo
printf '按回车键关闭窗口...'
IFS= read -r _
