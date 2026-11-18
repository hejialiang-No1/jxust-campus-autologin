# JXUST-WLAN 校园网自动登录（Windows + macOS）

> 仓库：<https://github.com/hejialiang-No1/jxust-campus-autologin>（公开仓库，不含任何真实账号或密码）
> Clone 或 Download ZIP 后，把文件夹放到一个**不会移动**的位置再按下面「快速开始」操作。
> macOS 从 ZIP 解压后若双击 `.command` 被系统拦，先在终端执行 `chmod +x 首次配置.command`。

江西理工大学 `jxust-wlan` / 锐捷 ePortal 自动认证。**首次填一次一卡通号、密码、网络服务商**，之后开机、Wi-Fi 断开重连、掉线恢复全部自动完成，不再输入、不再弹登录网页。

两个平台都是零依赖：macOS 用自带 bash + launchd + 钥匙串；Windows 用自带 PowerShell 5.1 + 计划任务 + DPAPI。

---

## 1. 目录

| 路径 | 说明 |
|---|---|
| `首次配置.command` | **macOS 入口**：双击，首次填账号密码服务商 |
| `campus-autologin` | macOS 主程序（CLI） |
| `config.env` | macOS 配置模板（接口 / 判据 / 周期） |
| `install.sh` | macOS 部署脚本（拷到 `~/.local/bin` 并注册守护） |
| `一键启用.command` | macOS 手动重载守护 / 弹窗自检（一般用不到） |
| `windows/首次配置.bat` | **Windows 入口**：双击，首次填账号密码服务商 |
| `windows/CampusAutoLogin.ps1` | Windows 主程序 |
| `windows/查看状态.bat` / `立即认证.bat` / `卸载.bat` | Windows 常用操作 |
| `multi-device/` | 路由器 / 其他设备方案的**本地私有笔记**，含个人账号与明文密码，已被 `.gitignore` 排除，不入库 |

---

## 2. 快速开始

| 步骤 | macOS | Windows |
|---|---|---|
| 1 | 连上 `jxust-wlan`（**先别在网页里登录**） | 连上 `jxust-wlan`（先别登录） |
| 2 | 双击 `首次配置.command` | 双击 `windows/首次配置.bat` |
| 3 | 输入一卡通号 / 密码 / 服务商 | 输入一卡通号 / 密码 / 服务商 |
| 4 | 系统弹「自动化授权」点「好」 | **建议右键 → 以管理员身份运行**（彻底关弹窗） |
| 5 | 自动部署、自检、立即认证一次 | 自动部署、自检、立即认证一次 |

之后什么都不用管。再运行一次入口文件 = 改配置（回车保持原值，密码可留空不重输）。

> 运营商后缀：移动 `@cmcc`、电信 `@telecom`、联通 `@unicom`、校园网无后缀。登录报「账号或密码错误」优先换后缀重试。

---

## 3. 功能对照

| 能力 | macOS | Windows |
|---|---|---|
| 首次交互式录入 + 记住凭据 | ✅ | ✅ |
| 凭据加密存储 | macOS 钥匙串（`campus-autologin`） | DPAPI（`%LOCALAPPDATA%\CampusAutoLogin\cred.bin`，仅当前用户+本机可解） |
| 开机自启 | LaunchAgent：`RunAtLoad` + `WatchPaths` + 30s 兜底 | 启动文件夹 VBS + 计划任务（登录触发 + 每 5 分钟保活） |
| Wi-Fi 断开重连 | `WatchPaths` 即时触发 + DHCP 就绪短轮询 | 常驻循环 2s 短轮询（网络未就绪）/ 10s 空闲 |
| 掉线恢复 | 三态判定 + 失败指数退避 | 同左 |
| 不弹登录网页 | 极速认证 + 认证成功后自动收起 CNA 窗口 / 浏览器 Portal 标签 | 极速认证 + 认证成功后自动关 NCSI 窗口 + 管理员下禁用主动探测 |
| 单实例保护 | launchd 自身保证 | 命名互斥锁 + 进程检查 |
| 日志 | `~/Library/Logs/campus-autologin.log` | `%LOCALAPPDATA%\CampusAutoLogin\campus-autologin.log` |

---

## 4. 认证协议（已在本校网关实测）

```
GET http://10.17.8.18:801/eportal/portal/login
    ?callback=dr1003
    &login_method=1
    &user_account=<一卡通号>%40cmcc      ← @ 必须 URL 编码
    &user_password=<密码>                 ← 整体 URL 编码
```

- `login_method=1` 是**认证协议**，不是运营商；运营商完全由账号后缀决定。
- 在线判定只认网关首页 `http://10.17.8.18/`：
  - 已认证 → `<title>注销页</title>` / `Dr.COMWebLoginID_1.htm`
  - 未认证 → `<title>上网登录页</title>` / `Dr.COMWebLoginID_0.htm`
  - **不用** `captive.apple.com`、`msftconnecttest.com` 判在线：本校 CDN 缓存会让未认证时也返回 `Success`。
- 网关页面是 GBK；判据里的 ASCII 标记（`_1.htm` / `_0.htm`）不受编码影响。
- 三态：`0=已认证`、`1=网关可达但未认证`、`2=网络未就绪`。第 2 态**不提交、不退避**，网络一恢复立刻抢在系统弹窗前认证。
- macOS 多网卡（iPhone USB 热点抢默认路由）时，所有请求绑定 Wi-Fi 接口 `en0`。

---

## 5. 「不弹登录网页」是怎么做到的

连通 Wi-Fi 到认证完成之间有 1~3 秒空窗，系统的 Captive Portal 探测（macOS `captiveagent` / Windows NCSI）会在这几秒里判定「需要登录」并弹窗。三层处理：

1. **抢时间**：DHCP 一拿到 IP 就短轮询网关，立即提交认证，跳过防抖。
2. **关残留**：认证成功后自动关闭已弹出的窗口 / Portal 标签页。
3. **禁探测**（仅 Windows，需管理员）：写 `NoActiveProbe=1` / `DisablePassivePolling=1` / `EnableActiveProbing=0`。

> macOS 26/27 的 `captiveagent` 已不读老的 `com.apple.captive.control Active=false`，所以 macOS 侧靠 1+2，不做无效的系统级改动。
>
> Windows 关探测的副作用：Wi-Fi 图标可能一直显示「无 Internet」（实际能上网）。运行 `卸载.bat` 会还原。
>
> 两边都建议：浏览器主页用 HTTPS、关掉「启动时恢复上次标签页」，避免认证前那两秒的 HTTP 请求被 AC 302 成登录页标签。

---

## 6. 常用命令

| 目的 | macOS | Windows |
|---|---|---|
| 看状态 | `~/.local/bin/campus-autologin status` | 双击 `查看状态.bat` |
| 立即认证 | `... login` | 双击 `立即认证.bat` |
| 收掉已弹窗口 | `... close-popup` | `... -Action ClosePopup` |
| 自启自检/修复 | `... autostart` | 重新双击 `首次配置.bat` |
| 看日志 | `... log` | `查看状态.bat` 末尾 12 行 |
| 改账号密码 | 重新双击 `首次配置.command` | 重新双击 `首次配置.bat` |
| 卸载自启 | `... uninstall` | 双击 `卸载.bat` |

---

## 7. 排查

| 现象 | 处理 |
|---|---|
| 一直不认证 | 看日志；确认连的是 `jxust-wlan`；确认账号后缀（移动 `@cmcc`） |
| 报「账号或密码错误」 | 换后缀重试；确认在校内、账号没在别的设备同时在线（学校一账号同时只允许一个设备） |
| 日志刷 HTTP 000 / 网关不可达 | 正常：断网 / DHCP 未就绪，脚本会短轮询等待，不算失败、不退避 |
| 已登录但还闪一下登录页 | 空窗期残留；认证成功后会自动收起。Windows 用管理员跑一次可彻底禁弹 |
| Windows 计划任务注册失败 | 正常，启动文件夹 VBS 已兜底，开机自启不受影响 |
| macOS 提示无法注册 launchd | 在「终端.app」里双击 `首次配置.command`（WorkBuddy / 非 GUI 会话会被系统拒绝） |
| 学校换了认证系统 | macOS 连上未认证校园网跑 `campus-autologin probe` 或 `import-curl`；改 `config.env` 的接口与判据即可，Windows 改 `config.json` |

---

## 8. 安全 / 分发注意

- 密码**不落盘明文**：macOS 钥匙串、Windows DPAPI。配置文件和日志都不含密码。
- 若凭据被换 Windows 用户 / 重装系统，解密会失败，重跑一次首次配置即可。
- 仓库里**不包含任何真实账号或密码**：`config.env` 的 `USERNAME` 为空，密码只存在本机钥匙串 / DPAPI 加密文件里。
- `multi-device/` 是早期多设备方案的本地私有笔记，**含明文密码**，已由 `.gitignore` 排除；千万别用 `git add -f` 强制加入。
- 学校规定一个账号同一时间只能在线一台设备；多设备共享（路由器 NAT / OpenWrt）有校规与防代理风险，相关脚本仅在本地 `multi-device/`。

---

## 9. 卸载

- macOS：`~/.local/bin/campus-autologin uninstall`（配置/钥匙串保留）；彻底删除请自行清理 `~/.config/campus-autologin` 与钥匙串项 `campus-autologin`。
- Windows：双击 `卸载.bat`（配置与密码保留，同时还原系统联网探测）。
