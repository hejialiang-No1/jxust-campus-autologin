# Windows 版 · 使用说明

适用 Windows 10 / 11，自带 PowerShell 5.1，无需装任何东西、无需联网下载依赖。

## 安装（只做一次）

1. 把整个 `windows/` 文件夹放到一个**不会移动**的位置，例如 `D:\Tools\CampusAutoLogin\`。
   > 别放桌面再移动、别放在需要管理员权限才能读的目录；脚本路径会被写进自启项。
2. 连上 `jxust-wlan`，**先别在网页里登录**。
3. 右键 `首次配置.bat` → **以管理员身份运行**（推荐）。
   - 非管理员也能装：开机自启、自动认证、自动关窗全部有效；只有「彻底禁用系统联网探测」这一步会被跳过。
4. 按提示输入：
   - 一卡通号（例：`20230001`）
   - 一卡通密码（不回显）
   - 网络服务商：`1` 移动 `@cmcc` / `2` 电信 `@telecom` / `3` 联通 `@unicom` / `4` 无后缀
5. 脚本自动写自启、关弹窗、立即认证一次，并显示当前状态。

之后开机登录 Windows、Wi-Fi 断开重连、校园网掉线恢复，都会自动认证，不用再输入。

> 想改配置：重新运行 `首次配置.bat`，账号/密码/服务商处**直接回车 = 保持原值**。

## 文件位置

| 内容 | 路径 |
|---|---|
| 配置（账号、后缀、接口、判据） | `%LOCALAPPDATA%\CampusAutoLogin\config.json` |
| 密码（DPAPI 加密） | `%LOCALAPPDATA%\CampusAutoLogin\cred.bin` |
| 日志 | `%LOCALAPPDATA%\CampusAutoLogin\campus-autologin.log` |
| 开机自启 A | 启动文件夹 `CampusAutoLogin.vbs`（无黑框拉起后台守护） |
| 开机自启 B | 计划任务 `CampusAutoLogin-JXUST`（登录触发 + 每 5 分钟保活） |

`cred.bin` 用当前 Windows 账户的 DPAPI 密钥加密，换用户、拷到别的电脑都解不开。

## 开机自启 / 重连机制

后台守护 `-Action Watch` 常驻循环：

| 网络状态 | 轮询间隔 | 动作 |
|---|---|---|
| 已认证 | 10s | 静默 |
| 非 `jxust-wlan` | 10s | 静默（不会乱提交） |
| 网关不可达（刚连 Wi-Fi / DHCP 未发 IP） | 2s | 短轮询等就绪，**不提交、不退避** |
| 网关可达但未认证 | 立即 | 提交认证，成功后关弹窗 |
| 连续失败 | 20s → 40s → … 上限 300s | 指数退避，避免刷屏 |

命名互斥锁 + 进程检查保证只有一个守护在跑；计划任务每 5 分钟兜底，守护被误关也会被拉起。

## 不弹登录网页

1. 极速认证：DHCP 一就绪就抢在 Windows NCSI 探测前完成。
2. 认证成功后自动关闭标题含 `MSFT Connect Test` / `登录到网络` 之类的窗口。
3. 管理员运行时写注册表禁用主动探测：
   - `HKLM\SOFTWARE\Policies\Microsoft\Windows\Network Connectivity Status Indicator` → `NoActiveProbe=1`、`DisablePassivePolling=1`
   - `HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet` → `EnableActiveProbing=0`

**副作用**：Wi-Fi 图标可能显示「无 Internet（已连接）」，但网是通的。`卸载.bat` 会还原全部改动；也可单独执行：

```bat
powershell -ExecutionPolicy Bypass -File CampusAutoLogin.ps1 -Action RestoreProbe
```

浏览器侧建议：主页设成 HTTPS、关掉「启动时恢复上次标签页」，认证前那两秒就不会有 HTTP 请求被校园网 302 成登录页标签。

## 常用操作

| 双击 | 作用 |
|---|---|
| `查看状态.bat` | 账号、SSID、网关状态、自启状态、最近 12 条日志 |
| `立即认证.bat` | 手动跑一次认证 + 收掉已弹窗口 |
| `卸载.bat` | 移除自启、停守护、还原系统探测（配置和密码保留） |

命令行等价写法（管理员 PowerShell / CMD 均可）：

```bat
powershell -ExecutionPolicy Bypass -File CampusAutoLogin.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File CampusAutoLogin.ps1 -Action Login
powershell -ExecutionPolicy Bypass -File CampusAutoLogin.ps1 -Action ClosePopup
powershell -ExecutionPolicy Bypass -File CampusAutoLogin.ps1 -Action Install
powershell -ExecutionPolicy Bypass -File CampusAutoLogin.ps1 -Action Uninstall
```

## 排查

| 现象 | 处理 |
|---|---|
| 双击 .bat 一闪而过 | 右键用管理员运行；或在 CMD 里手动执行上面命令看报错 |
| 提示「尚未配置账号密码」 | 先跑 `首次配置.bat` |
| 一直「未认证」 | 看 `查看状态.bat` 的 SSID 是不是 `jxust-wlan`；换服务商后缀重试 |
| 密码解密失败 | 换了 Windows 用户 / 重装过系统，重跑首次配置 |
| 管理员跑完却提示「尚未配置」 | 用的是**另一个管理员账号**提权，配置写进了那个账号的 `%LOCALAPPDATA%`。改回普通双击 `首次配置.bat` 写配置，注册表那步单独用管理员跑 `-Action Install` |
| 计划任务注册被拒 | 公司/学校策略限制，启动文件夹 VBS 已兜底，开机自启不受影响 |
| 换过认证系统 | 改 `config.json` 的 `LoginUrl` / `OnlineRegex` / `OfflineRegex` 即可，不用改脚本 |

## 卸载

双击 `卸载.bat`：删除启动文件夹启动器与计划任务、停掉后台守护、还原 NCSI 注册表。配置和密码文件保留，重新运行首次配置即可恢复；想彻底清理，手动删除 `%LOCALAPPDATA%\CampusAutoLogin`。
