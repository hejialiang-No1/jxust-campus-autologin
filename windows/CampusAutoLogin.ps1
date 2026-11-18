<#
  CampusAutoLogin.ps1 — 江西理工大学 JXUST-WLAN 校园网自动认证 (Windows)
  兼容 Windows PowerShell 5.1 (Win10/11 自带)，无需管理员、无需第三方依赖。

  用法:
    powershell -ExecutionPolicy Bypass -File CampusAutoLogin.ps1 -Action Setup
  动作: Setup / Watch / Login / Status / Install / Uninstall / ClosePopup / RestoreProbe
#>
[CmdletBinding()]
param(
  [ValidateSet('Setup','Watch','Login','Status','Install','Uninstall','ClosePopup','RestoreProbe')]
  [string]$Action = 'Setup',
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$script:Quiet      = [bool]$Quiet
$script:SelfPath   = $MyInvocation.MyCommand.Path
$script:DataDir    = Join-Path $env:LOCALAPPDATA 'CampusAutoLogin'
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:CredPath   = Join-Path $script:DataDir 'cred.bin'
$script:LogPath    = Join-Path $script:DataDir 'campus-autologin.log'
$script:TaskName   = 'CampusAutoLogin-JXUST'
$script:StartupVbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'CampusAutoLogin.vbs'
$script:PassPlain  = ''
$script:FailCount  = 0
$script:LastTry    = [DateTime]::MinValue
$script:WasOffline = $false

if (-not (Test-Path -LiteralPath $script:DataDir)) {
  New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
}

# 密码用 DPAPI (ConvertFrom-SecureString) 加密，只有当前 Windows 用户 + 本机可解。
# 目录本身在 %LOCALAPPDATA% 下，也只对该用户开放。
# PS 5.1 读无 BOM 的 UTF-8 会按 ANSI 解码导致中文乱码，所以落盘文件统一带 BOM，
# 追加写时用 NoBom 避免每段日志前面都多一个 BOM。
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Utf8Bom   = [System.Text.UTF8Encoding]::new($true)
$script:CredWarned = $false

$script:DefaultConfig = [ordered]@{
  Username       = ''
  Suffix         = '@cmcc'
  SsidMatch      = 'jxust-wlan'
  LoginUrl       = 'http://10.17.8.18:801/eportal/portal/login'
  CheckUrl       = 'http://10.17.8.18/'
  OnlineRegex    = '注销页|Dr\.COMWebLoginID_1\.htm'
  OfflineRegex   = '上网登录页|Dr\.COMWebLoginID_0\.htm'
  FastWaitSec    = 20
  FastPollSec    = 2
  IdleSec        = 10
  BusySec        = 2
  DebounceSec    = 20
  MaxBackoff     = 300
  ClosePopup     = $true
}

# ---------------------------------------------------------------- 工具函数
function Write-Log {
  param([string]$Message)
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
  if ($script:PassPlain) { $line = $line.Replace($script:PassPlain, '********') }
  try {
    if (-not (Test-Path -LiteralPath $script:LogPath)) {
      [System.IO.File]::WriteAllText($script:LogPath, '', $script:Utf8Bom)
    }
    [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $script:Utf8NoBom)
    $fi = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
    if ($fi -and $fi.Length -gt 900000) {
      $keep = Get-Content -LiteralPath $script:LogPath -Tail 1500 -Encoding UTF8
      [System.IO.File]::WriteAllText($script:LogPath, ($keep -join "`r`n") + "`r`n", $script:Utf8Bom)
    }
  } catch { }
  if (-not $script:Quiet) { Write-Host $line }
}

function Get-Config {
  $cfg = [ordered]@{}
  foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
  if (Test-Path -LiteralPath $script:ConfigPath) {
    try {
      $raw = (Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8).TrimStart([char]0xFEFF)
      $obj = $raw | ConvertFrom-Json
      foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    } catch { Write-Log "配置读取失败，使用默认值: $($_.Exception.Message)" }
  }
  Write-Output -NoEnumerate $cfg
}

function Save-Config {
  param($Config)
  # 必须用 -InputObject：走管道时 OrderedDictionary 可能被枚举成 DictionaryEntry 数组，
  # 写出来的 config.json 会变成 JSON 数组而不是对象，下次读就全丢。
  $json = ConvertTo-Json -InputObject $Config -Depth 4
  [System.IO.File]::WriteAllText($script:ConfigPath, $json, $script:Utf8Bom)
}

function Convert-SecureToPlain {
  param([System.Security.SecureString]$Secure)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-PasswordPlain {
  if (-not (Test-Path -LiteralPath $script:CredPath)) { return $null }
  try {
    $enc = (Get-Content -LiteralPath $script:CredPath -Raw -Encoding UTF8).Trim()
    $sec = $enc | ConvertTo-SecureString
    return (Convert-SecureToPlain $sec)
  } catch {
    if (-not $script:CredWarned) {
      $script:CredWarned = $true
      Write-Log '密码解密失败（换了 Windows 用户/重装系统后需重新运行首次配置）'
    }
    return $null
  }
}

function Save-Password {
  param([System.Security.SecureString]$Secure)
  $enc = $Secure | ConvertFrom-SecureString
  [System.IO.File]::WriteAllText($script:CredPath, $enc, $script:Utf8NoBom)
}

function Test-Admin {
  try {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr  = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Get-WifiSsid {
  try {
    $lines = & netsh wlan show interfaces 2>$null
    foreach ($l in $lines) {
      if ($l -match '^\s*(SSID|网络名|服务集标识符)\s*[:：]\s*(.+?)\s*$') { return $Matches[2] }
    }
  } catch { }
  return ''
}

# 绕开 IE / 系统代理，直接发 HTTP 请求；返回网关页面文本 (GBK 解码)
function Invoke-HttpGet {
  param([string]$Url, [int]$TimeoutMs = 5000)
  $req = [System.Net.HttpWebRequest]::Create($Url)
  $req.Method             = 'GET'
  $req.Timeout            = $TimeoutMs
  $req.ReadWriteTimeout   = $TimeoutMs
  $req.Proxy              = $null
  $req.KeepAlive          = $false
  $req.AllowAutoRedirect  = $true
  $req.UserAgent          = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36'
  try { $req.ServicePoint.Expect100Continue = $false } catch { }
  $resp = $null
  try {
    $resp    = $req.GetResponse()
    $stream  = $resp.GetResponseStream()
    $ms      = [System.IO.MemoryStream]::new()
    $buf     = [byte[]]::new(8192)
    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    $bytes = $ms.ToArray()
    $ms.Close()
    try { return [System.Text.Encoding]::GetEncoding(936).GetString($bytes) }
    catch { return [System.Text.Encoding]::UTF8.GetString($bytes) }
  } finally {
    if ($resp) { $resp.Close() }
  }
}

# 0 = 已认证 / 1 = 网关可达但未认证 / 2 = 网络未就绪 (刚连 Wi-Fi、DHCP 没发完 IP)
function Get-PortalState {
  param($Config)
  try { $body = Invoke-HttpGet -Url $Config.CheckUrl -TimeoutMs 4500 }
  catch { return 2 }
  if ([string]::IsNullOrEmpty($body)) { return 2 }
  if ($body -match $Config.OfflineRegex) { return 1 }
  if ($body -match $Config.OnlineRegex)  { return 0 }
  return 1
}

function Invoke-PortalLogin {
  param($Config, [string]$User, [string]$Pass)
  $q = 'callback=dr1003&login_method=1' +
       '&user_account='  + [Uri]::EscapeDataString($User) +
       '&user_password=' + [Uri]::EscapeDataString($Pass)
  $url = $Config.LoginUrl + '?' + $q
  $script:LastTry = Get-Date
  $body = ''
  try { $body = Invoke-HttpGet -Url $url -TimeoutMs 12000 }
  catch { Write-Log "认证请求异常: $($_.Exception.Message)" }
  Start-Sleep -Seconds 1
  if ((Get-PortalState $Config) -eq 0) { return $true }
  # 服务端回「已经在线」：凭据有效，按成功处理，否则会白触发退避
  if ($body -match '已经在线|already online|ret_code"?[: ]*2') { return $true }
  Write-Log ('认证未生效，响应片段: ' + $body.Substring(0, [Math]::Min(300, $body.Length)))
  return $false
}

# ---------------------------------------------------------------- 弹窗抑制
$script:Win32Code = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CalWindow {
  private delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static int Close(string[] keys) {
    int count = 0;
    List<IntPtr> hits = new List<IntPtr>();
    EnumProc cb = delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      StringBuilder sb = new StringBuilder(512);
      GetWindowText(h, sb, sb.Capacity);
      string t = sb.ToString().ToLowerInvariant();
      if (t.Length == 0) return true;
      foreach (string k in keys) {
        if (k.Length > 0 && t.IndexOf(k.ToLowerInvariant(), StringComparison.Ordinal) >= 0) {
          hits.Add(h); break;
        }
      }
      return true;
    };
    EnumWindows(cb, IntPtr.Zero);
    foreach (IntPtr h in hits) {
      if (PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero)) count++;
    }
    return count;
  }
}
'@

function Close-PortalWindows {
  try {
    if (-not ('CalWindow' -as [type])) {
      Add-Type -TypeDefinition $script:Win32Code -Language CSharp -ErrorAction Stop | Out-Null
    }
    $keys = @('msftconnecttest', 'connecttest', 'connect test', 'network connectivity status',
              'sign in to network', 'network login', '登录到网络', '需要登录',
              '网络登录', '需要执行操作', '其他登录信息', 'captive portal')
    $n = [CalWindow]::Close($keys)
    if ($n -gt 0) { Write-Log "已关闭 $n 个系统弹出的登录页窗口" }
    return $n
  } catch { return 0 }
}

# 管理员下写 NCSI 注册表：关掉 Windows 的主动联网探测，从源头不弹「需要登录」提示。
# 副作用：Wi-Fi 图标可能一直显示「无 Internet」（实际能上网）。用 RestoreProbe 可还原。
function Set-NoPopup {
  if (-not (Test-Admin)) {
    Write-Host '  [--] 当前不是管理员，跳过系统级联网探测开关（快速认证 + 自动关窗仍生效）'
    Write-Host '       想彻底不弹：右键「首次配置.bat」→ 以管理员身份运行一次'
    return $false
  }
  try {
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Network Connectivity Status Indicator'
    $nla = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
    if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
    New-ItemProperty -Path $pol -Name 'NoActiveProbe'         -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $pol -Name 'DisablePassivePolling' -Value 1 -PropertyType DWord -Force | Out-Null
    if (Test-Path $nla) {
      New-ItemProperty -Path $nla -Name 'EnableActiveProbing' -Value 0 -PropertyType DWord -Force | Out-Null
    }
    Write-Host '  [OK] 已关闭 Windows 联网探测（NCSI），不会再弹「需要登录」提示'
    Write-Log '已写入 NCSI 注册表，禁用主动探测'
    return $true
  } catch {
    Write-Host "  [--] NCSI 设置写入失败: $($_.Exception.Message)"
    return $false
  }
}

function Restore-Popup {
  if (-not (Test-Admin)) { Write-Host '需要管理员权限：右键「卸载.bat」→ 以管理员身份运行'; return }
  try {
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Network Connectivity Status Indicator'
    $nla = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
    Remove-ItemProperty -Path $pol -Name 'NoActiveProbe'         -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $pol -Name 'DisablePassivePolling' -ErrorAction SilentlyContinue
    if (Test-Path $nla) {
      New-ItemProperty -Path $nla -Name 'EnableActiveProbing' -Value 1 -PropertyType DWord -Force | Out-Null
    }
    Write-Host '已恢复 Windows 默认联网探测。'
  } catch { Write-Host "恢复失败: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- 开机自启
function Install-AutoStart {
  $self   = $script:SelfPath
  $psExe  = (Get-Process -Id $PID).Path
  $argFmt   = '-NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "{0}" -Action Watch -Quiet'
  $taskArgs = [string]::Format($argFmt, $self)

  # 1) 启动文件夹 VBS 启动器（普通用户 100% 可用，无黑框）
  $vbs = @'
Option Explicit
Dim fso, sh, p, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
p = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "CampusAutoLogin.ps1")
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & p & """ -Action Watch -Quiet"
sh.Run cmd, 0, False
'@
  [System.IO.File]::WriteAllText($script:StartupVbs, $vbs, [System.Text.ASCIIEncoding]::new())
  Write-Host '  [OK] 启动文件夹自启已写入'

  # 2) 计划任务：登录时启动 + 每 5 分钟保活（常驻进程被误关也能自动拉起）。
  #    不同 Win10/11 版本对被管设备上的计划任务权限限制不同，失败就降级注册。
  $ok = $false
  try {
    $act   = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
    $tLog  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $tKeep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
               -RepetitionInterval (New-TimeSpan -Minutes 5) `
               -RepetitionDuration (New-TimeSpan -Days 3650)
    $set   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
               -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    $prin  = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
               -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $script:TaskName -Action $act `
      -Trigger @($tLog, $tKeep) -Settings $set -Principal $prin -Force `
      -ErrorAction Stop | Out-Null
    Write-Host '  [OK] 计划任务已注册（登录自启 + 每 5 分钟保活）'
    $ok = $true
  } catch { }
  if (-not $ok) {
    try {
      $act  = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
      $tLog = New-ScheduledTaskTrigger -AtLogOn
      Register-ScheduledTask -TaskName $script:TaskName -Action $act `
        -Trigger $tLog -Force -ErrorAction Stop | Out-Null
      Write-Host '  [OK] 计划任务已注册（登录自启，简化模式）'
      $ok = $true
    } catch {
      Write-Host '  [--] 计划任务被系统策略拒绝，已用启动文件夹自启（功能不受影响）'
    }
  }
  Write-Log "开机自启已安装 (计划任务=$ok)"
}

function Uninstall-AutoStart {
  try { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop | Out-Null }
  catch { }
  Remove-Item -LiteralPath $script:StartupVbs -Force -ErrorAction SilentlyContinue
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
    foreach ($p in $procs) {
      if ($p.CommandLine -like '*CampusAutoLogin.ps1*Watch*') {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
  Write-Host '开机自启已移除，后台守护已停止。'
}

function Get-AutoStartState {
  $vbs = Test-Path -LiteralPath $script:StartupVbs
  $task = $false
  try { $task = [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop) } catch { }
  return @($vbs, $task)
}

# ---------------------------------------------------------------- 核心循环
# 返回本轮结束后应休眠的秒数；网络未就绪 / 刚认证时短轮询，已在线时长休眠
function Invoke-CheckOnce {
  param($Config, [string]$User, [string]$Pass, [bool]$Force = $false)

  $ssid = Get-WifiSsid
  if ($Config.SsidMatch -and $ssid -and ($ssid -notmatch [regex]::Escape([string]$Config.SsidMatch))) {
    $script:FailCount  = 0
    $script:WasOffline = $false
    return [int]$Config.IdleSec
  }

  $st = Get-PortalState $Config

  if ($st -eq 0) {
    if ($script:WasOffline) { Write-Log '网络恢复且已认证' }
    $script:FailCount  = 0
    $script:WasOffline = $false
    return [int]$Config.IdleSec
  }

  # 断网 / Wi-Fi 刚重连 / DHCP 未就绪：不提交、不退避，短轮询等网关可达
  if ($st -eq 2) {
    $script:FailCount  = 0
    $script:WasOffline = $true
    $waited = 0
    $limit  = [int]$Config.FastWaitSec
    $step   = [int]$Config.FastPollSec
    if ($step -lt 1) { $step = 2 }
    while ($waited -lt $limit) {
      Start-Sleep -Seconds $step
      $waited += $step
      $st = Get-PortalState $Config
      if ($st -ne 2) { break }
    }
    if ($st -eq 2) { return $step }
    if ($st -eq 0) { $script:WasOffline = $false; return [int]$Config.IdleSec }
    # 从「不可达」恢复到「未认证」：跳过防抖，抢在 NCSI 弹窗之前认证
    Write-Log "网络刚恢复 (SSID=$ssid)，立即认证"
    $ok = Invoke-PortalLogin $Config $User $Pass
    if ($ok) {
      $script:FailCount  = 0
      $script:WasOffline = $false
      Write-Log '认证成功 已恢复联网'
      if ($Config.ClosePopup) { $null = Close-PortalWindows }
      return [int]$Config.BusySec
    }
    return [int]$Config.BusySec
  }

  # st = 1：网关可达但未认证
  $backoff = [int]$Config.DebounceSec
  for ($i = 0; $i -lt $script:FailCount -and $backoff -lt [int]$Config.MaxBackoff; $i++) {
    $backoff = $backoff * 2
  }
  if ($backoff -gt [int]$Config.MaxBackoff) { $backoff = [int]$Config.MaxBackoff }
  $elapsed = ((Get-Date) - $script:LastTry).TotalSeconds
  if (-not $Force -and $elapsed -lt $backoff) { return [int]$Config.BusySec }

  Write-Log "检测到未认证 (SSID=$ssid)，开始认证"
  $ok = Invoke-PortalLogin $Config $User $Pass
  if ($ok) {
    $script:FailCount  = 0
    $script:WasOffline = $false
    Write-Log '认证成功 已恢复联网'
    if ($Config.ClosePopup) { $null = Close-PortalWindows }
  } else {
    $script:FailCount++
    Write-Log "认证失败，退避 ${backoff}s（连续失败 $($script:FailCount) 次）"
  }
  return [int]$Config.BusySec
}

function Get-FullAccount {
  param($Config)
  $u = ([string]$Config.Username).Trim()
  if ($u -like '*@*') { return $u }
  return $u + ([string]$Config.Suffix)
}

# ---------------------------------------------------------------- 各动作
function Invoke-Setup {
  Write-Host ''
  Write-Host '====== 江西理工大学 JXUST-WLAN 校园网自动认证 · 首次配置 ======'
  Write-Host ''
  $cfg = Get-Config

  $oldUser = ([string]$cfg.Username).Trim()
  $tip = '一卡通号'
  if ($oldUser) { $tip = "一卡通号 [回车保持 $oldUser]" }
  $in = Read-Host $tip
  if ([string]::IsNullOrWhiteSpace($in)) { $in = $oldUser }
  if ([string]::IsNullOrWhiteSpace($in)) { Write-Host '账号不能为空，已退出。'; return }
  $cfg.Username = $in.Trim()

  $oldPass  = Get-PasswordPlain
  $newSec   = $null
  if ($oldPass) {
    $s = Read-Host '密码 [直接回车保持原密码；要改就输新密码，不回显]' -AsSecureString
    if ($s.Length -gt 0) { $newSec = $s }
  } else {
    $s = Read-Host '一卡通密码（输入不回显）' -AsSecureString
    if ($s.Length -eq 0) { Write-Host '密码不能为空，已退出。'; return }
    $newSec = $s
  }
  if ($newSec) {
    Save-Password $newSec
    $pass = Convert-SecureToPlain $newSec
  } else {
    $pass = $oldPass
  }
  $script:PassPlain = $pass

  Write-Host ''
  Write-Host '网络服务商（决定账号后缀，密码不变）：'
  Write-Host '  1) 中国移动   @cmcc'
  Write-Host '  2) 中国电信   @telecom'
  Write-Host '  3) 中国联通   @unicom'
  Write-Host '  4) 校园网/无后缀'
  $cur = [string]$cfg.Suffix
  if (-not $cur) { $cur = '无后缀' }
  $choice = Read-Host "选择 1-4 [当前 $cur，回车保持]"
  switch ($choice) {
    '1' { $cfg.Suffix = '@cmcc' }
    '2' { $cfg.Suffix = '@telecom' }
    '3' { $cfg.Suffix = '@unicom' }
    '4' { $cfg.Suffix = '' }
  }

  Save-Config $cfg
  Write-Host ''
  $acct = Get-FullAccount $cfg
  Write-Host "  账号已保存: $acct（密码已用 DPAPI 加密，仅本机当前用户可解）"
  Write-Host ''
  Write-Host '====== 安装开机自启 ======'
  Install-AutoStart
  Write-Host ''
  Write-Host '====== 关闭 Windows 自动弹出的登录网页 ======'
  $null = Set-NoPopup
  Write-Host '  [OK] 认证成功后会自动收掉已经弹出的登录页窗口'

  Write-Host ''
  Write-Host '====== 立即验证一次 ======'
  $null = Invoke-CheckOnce -Config $cfg -User (Get-FullAccount $cfg) -Pass $pass -Force $true
  $state = Get-PortalState $cfg
  switch ($state) {
    0 { Write-Host '  当前状态：已认证 / 已联网' }
    1 { Write-Host '  当前状态：未认证（可能没连 JXUST-WLAN，或账号后缀不对；连上校园网后会自动重试）' }
    2 { Write-Host '  当前状态：校园网网关不可达（请先连上 JXUST-WLAN）' }
  }
  Write-Host ''
  Write-Host '配置完成。以后开机、Wi-Fi 断开重连都会自动认证，不用再输任何东西。'
  Write-Host "日志: $script:LogPath"
  Write-Host '改配置 / 看状态：双击「查看状态.bat」或重新运行「首次配置.bat」'
  Write-Host ''
}

function Invoke-Watch {
  # 单实例：Local\ 命名互斥 + 进程检查，防止计划任务保活时起多个守护
  $created = $false
  try {
    $script:WatchMutex = [System.Threading.Mutex]::new($true, 'Local\CampusAutoLoginWatch', [ref]$created)
    if (-not $created) { exit 0 }
  } catch { Write-Log '互斥锁创建失败，改用进程检查' }
  try {
    $me = $PID
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
    foreach ($p in $procs) {
      if ($p.ProcessId -ne $me -and $p.CommandLine -like '*CampusAutoLogin.ps1*Watch*') { exit 0 }
    }
  } catch { }

  Write-Log '守护启动（Wi-Fi 重连 / 掉线 / 重启后自动认证）'
  while ($true) {
    try {
      $cfg  = Get-Config
      $pass = Get-PasswordPlain
      if (-not $pass -or -not ([string]$cfg.Username).Trim()) {
        Start-Sleep -Seconds 15
        continue
      }
      $script:PassPlain = $pass
      $sleep = Invoke-CheckOnce -Config $cfg -User (Get-FullAccount $cfg) -Pass $pass
      Start-Sleep -Seconds ([int]$sleep)
    } catch {
      Write-Log "守护异常: $($_.Exception.Message)"
      Start-Sleep -Seconds 5
    }
  }
}

function Invoke-Once {
  $cfg  = Get-Config
  $pass = Get-PasswordPlain
  if (-not $pass -or -not ([string]$cfg.Username).Trim()) {
    Write-Host '尚未配置账号密码，请先运行「首次配置.bat」'
    return
  }
  $script:PassPlain = $pass
  $null = Invoke-CheckOnce -Config $cfg -User (Get-FullAccount $cfg) -Pass $pass -Force $true
}

function Show-Status {
  $cfg  = Get-Config
  $pass = Get-PasswordPlain
  $a    = Get-AutoStartState
  Write-Host ''
  Write-Host '====== 校园网自动认证 · 状态 ======'
  $acct    = Get-FullAccount $cfg
  $pwdTxt  = '未设置'
  if ($pass) { $pwdTxt = '已保存(DPAPI 加密)' }
  $ssidTxt = Get-WifiSsid
  $st = Get-PortalState $cfg
  $txt = '未知'
  if ($st -eq 0) { $txt = '已认证 / 已联网' }
  elseif ($st -eq 1) { $txt = '未认证' }
  elseif ($st -eq 2) { $txt = '网关不可达 / 非校园网' }
  $vbsTxt  = '未启用'
  $taskTxt = '未启用'
  if ($a[0]) { $vbsTxt = '已启用' }
  if ($a[1]) { $taskTxt = '已启用' }
  Write-Host "  账号        : $acct"
  Write-Host "  密码        : $pwdTxt"
  Write-Host "  当前 SSID   : $ssidTxt"
  Write-Host "  网关状态    : $txt"
  Write-Host "  自启(启动夹): $vbsTxt"
  Write-Host "  自启(计划任务): $taskTxt"
  Write-Host "  配置文件    : $script:ConfigPath"
  Write-Host "  日志        : $script:LogPath"
  if (Test-Path -LiteralPath $script:LogPath) {
    Write-Host ''
    Write-Host '  --- 最近 12 条日志 ---'
    Get-Content -LiteralPath $script:LogPath -Tail 12 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
  }
  Write-Host ''
}

switch ($Action) {
  'Setup'        { Invoke-Setup }
  'Watch'        { Invoke-Watch }
  'Login'        { Invoke-Once }
  'Status'       { Show-Status }
  'Install'      { Install-AutoStart; $null = Set-NoPopup }
  'Uninstall'    { Uninstall-AutoStart; Write-Host '配置与密码保留，重新运行「首次配置.bat」即可恢复。' }
  'ClosePopup'   { $n = Close-PortalWindows; Write-Host "已关闭 $n 个登录页窗口" }
  'RestoreProbe' { Restore-Popup }
}
