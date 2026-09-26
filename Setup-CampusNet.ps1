<#
  Setup-CampusNet.ps1 -- One-time setup wizard + autostart installer
  校园网自动连接：设置向导 + 开机自启安装
  ================================================================
  What it does / 它做什么
    1. Detect the campus portal and auto-identify the login form fields
       (delegates to Connect-CampusNet.ps1 -ProbeJson)
    2. Ask for account/password, store the password with Windows DPAPI
    3. Run one real login attempt so you can see whether it works
    4. Offer to install autostart (scheduled task, or a Startup shortcut)

  Usage / 用法
    .\Setup-CampusNet.ps1            # configure (existing config is used as defaults)
    .\Setup-CampusNet.ps1 -Probe     # only probe + print, then exit
    .\Setup-CampusNet.ps1 -Test      # re-run one login attempt, change nothing
    .\Setup-CampusNet.ps1 -Uninstall # remove autostart

  Security / 安全
    The password is encrypted with Windows DPAPI (CurrentUser scope): the
    ciphertext only decrypts for the SAME Windows user on the SAME machine.
    Copying the config file elsewhere will not reveal the password.
    Consequence: re-run this wizard after a reinstall or a machine change.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Probe,
    [switch]$Uninstall,
    [switch]$Test
)

$ErrorActionPreference = 'Continue'

$Root       = $PSScriptRoot
$ConfigPath = Join-Path $Root 'campus-net.config.json'
$MainScript = Join-Path $Root 'Connect-CampusNet.ps1'
$TaskName   = 'CampusNet-Autoconnect'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CampusNet-Autoconnect.lnk'

function Say  { param([string]$t) Write-Host $t }
function Head { param([string]$t) Write-Host ''; Write-Host ('==== ' + $t + ' ====') -ForegroundColor Cyan }
function Good { param([string]$t) Write-Host $t -ForegroundColor Green }
function Warn { param([string]$t) Write-Host $t -ForegroundColor Yellow }
function Bad  { param([string]$t) Write-Host $t -ForegroundColor Red }

function Ask {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) { $s = Read-Host ($Prompt + ' [' + $Default + ']') } else { $s = Read-Host $Prompt }
    if (-not $s) { return $Default }
    return $s
}

function Ask-Yes {
    param([string]$Prompt, [bool]$Default = $false)
    if ($Default) { $s = Read-Host ($Prompt + ' [Y/n]') } else { $s = Read-Host ($Prompt + ' [y/N]') }
    if (-not $s) { return $Default }
    return ($s -match '^(y|yes|Y|是|好)$')
}

function Get-Cfg2 {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    if ($p.Value -is [string] -and $p.Value -eq '') { return $Default }
    return $p.Value
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-WlanProfiles {
    $prev = $null
    try { $prev = [Console]::OutputEncoding } catch { }
    $raw = ''
    try {
        # netsh prints in the console codepage (936 on zh-CN); decode it correctly
        try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(936) } catch { }
        $raw = (netsh wlan show profiles 2>&1 | Out-String)
    } catch { } finally {
        if ($prev) { try { [Console]::OutputEncoding = $prev } catch { } }
    }
    $out = @()
    foreach ($m in [regex]::Matches($raw, ':\s*(.+?)\s*$', 'Multiline')) {
        $n = $m.Groups[1].Value.Trim()
        if ($n -and $n -notmatch '^(Profile|所有用户配置文件的策略|Group policy)') { $out += $n }
    }
    return $out
}

function Get-CurrentSsid {
    $prev = $null
    try { $prev = [Console]::OutputEncoding } catch { }
    $raw = ''
    try {
        try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(936) } catch { }
        $raw = (netsh wlan show interfaces 2>&1 | Out-String)
    } catch { } finally {
        if ($prev) { try { [Console]::OutputEncoding = $prev } catch { } }
    }
    $m = [regex]::Match($raw, '(?m)^\s*SSID\s*:\s*(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

# ==================== Uninstall ====================
if ($Uninstall) {
    Head 'Remove autostart / 移除开机自启'
    $done = $false
    try {
        $null = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Good ('Removed scheduled task / 已删除计划任务: ' + $TaskName)
        $done = $true
    } catch { }
    if (Test-Path -LiteralPath $StartupLnk) {
        Remove-Item -LiteralPath $StartupLnk -Force
        Good ('Removed startup shortcut / 已删除启动项: ' + $StartupLnk)
        $done = $true
    }
    if (-not $done) { Warn 'Nothing to remove. / 没有找到需要移除的自启项。' }
    Say 'Config and logs are kept. / 配置文件和日志保留在程序目录，未删除。'
    exit 0
}

# ==================== Test only ====================
if ($Test) {
    Head 'One login attempt / 试跑认证'
    if (-not (Test-Path -LiteralPath $MainScript)) { Bad ('Missing / 找不到: ' + $MainScript); exit 2 }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MainScript -Force
    exit $LASTEXITCODE
}

$old = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $old = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $old = $null }
}
$isAdmin = Test-Admin

Say ''
Say 'Campus network auto-login -- setup wizard / 校园网自动连接 —— 设置向导'
Say 'Press Enter to accept the value in [brackets]. / 一路回车即用中括号里的默认值。'
if (-not $isAdmin) { Say '(Not elevated: autostart will use a Startup shortcut instead of a scheduled task.)' }

# ==================== 1. Wi-Fi ====================
Head '1/5  Wi-Fi (skip for wired / 网线用户可跳过)'
$profiles = Get-WlanProfiles
$curSsid  = Get-CurrentSsid
if ($profiles.Count -gt 0) {
    Say 'Saved Wi-Fi profiles / 本机已保存的 Wi-Fi：'
    for ($i = 0; $i -lt $profiles.Count; $i++) { Say ('  [{0}] {1}' -f ($i + 1), $profiles[$i]) }
}
if ($curSsid) { Good ('Currently connected / 当前已连接: ' + $curSsid) }

$wifiDefault = [string](Get-Cfg2 $old 'WifiProfile' '')
if (-not $wifiDefault -and $curSsid) { $wifiDefault = $curSsid }
$wifiProfile = (Ask '  Wi-Fi profile name to auto-connect (empty = do not touch Wi-Fi)' $wifiDefault).Trim()

# ==================== 2. Probe ====================
Head '2/5  Detect the portal / 探测认证门户'
$portalUrl = [string](Get-Cfg2 $old 'LoginUrl' '')
$userField = [string](Get-Cfg2 $old 'UserField' '')
$pwdField  = [string](Get-Cfg2 $old 'PwdField'  '')
$mode      = [string](Get-Cfg2 $old 'Mode' 'Auto')

if (-not (Test-Path -LiteralPath $MainScript)) { Bad ('Missing / 找不到: ' + $MainScript); exit 2 }
Say 'Probing (about 10s) ... / 正在探测（约 10 秒）...'
$probeRaw = ''
try {
    $probeRaw = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MainScript -ProbeJson 2>$null | Out-String)
} catch { }
$probe = $null
try { $probe = ($probeRaw.Trim() | ConvertFrom-Json) } catch { $probe = $null }

if ($probe) {
    if ($probe.Online) {
        Good 'Currently ONLINE -- this is the best case: no authentication needed right now.'
        Warn 'Because you are online, the school'"'"'s login page cannot be captured.'
        Warn 'To get accurate field names: switch off Wi-Fi / unplug, then re-run this wizard.'
    } elseif ($probe.PortalUrl) {
        Good ('Portal detected / 探测到门户: ' + $probe.PortalUrl)
        if ($probe.Fields -and $probe.Fields.Count -gt 0) {
            Say ''
            Say 'Input fields found on the login page / 页面上的输入框：'
            foreach ($f in $probe.Fields) { Say ('  name={0}  type={1}  value={2}' -f $f.Name, $f.Type, $f.Value) }
            if (-not $userField) { $userField = [string]$probe.GuessUserField }
            if (-not $pwdField)  { $pwdField  = [string]$probe.GuessPwdField }
        } else {
            Warn 'No <input> parsed (the portal may be JS-rendered).'
        }
        if (-not $old) { $portalUrl = [string]$probe.PortalUrl; $mode = [string]$probe.GuessedMode }
    } else {
        Warn 'No portal redirect detected.'
        Warn 'Either you are already online, Wi-Fi is down, or the school requires a client app.'
    }
} else {
    Warn 'Probe produced no parsable result. You can fill the portal URL in by hand.'
}

Say ''
$manual = Ask 'Portal URL (paste it from the browser if the detected one is wrong; Enter = keep)' $portalUrl
if ($manual -match '^https?://') { $portalUrl = $manual.Trim() }

# ==================== 3. Credentials ====================
Head '3/5  Account / 账号密码'
if ($portalUrl) { Say ('  Portal / 门户: ' + $portalUrl) }
$userField = Ask '  name of the account input / 学号输入框的 name' $userField
$pwdField  = Ask '  name of the password input / 密码输入框的 name' $pwdField
$mode      = Ask '  Mode: Auto / Url (replay a captured request) / Query / Form' $mode
$pwdTf     = Ask '  PwdTransform: plain / base64 / md5  (most schools: plain)' (Get-Cfg2 $old 'PwdTransform' 'plain')
$pwdTpl    = Ask '  PwdTemplate ({pwd} {b64} {md5} {user} {token}; Dr.COM often needs 0{pwd})' (Get-Cfg2 $old 'PwdTemplate' '{pwd}')
$userSuffix = Ask '  UserSuffix (运营商后缀 如 @lt / @dx; 没有就回车。Dr.COM/城市热点 常用)' ([string](Get-Cfg2 $old 'UserSuffix' ''))
$allowBad  = Ask-Yes '  Allow invalid/self-signed TLS certificate? (needed by some portals)' ([bool](Get-Cfg2 $old 'AllowInvalidCert' $false))

$user = Ask '  Account / 学号 / 账号' ([string](Get-Cfg2 $old 'User' ''))
$pwdSec = Read-Host '  Password / 密码 (hidden; Enter = reuse the saved one)' -AsSecureString
$pwdPlain = ''
if ($pwdSec) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwdSec)
    try { $pwdPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$pwdEnc = [string](Get-Cfg2 $old 'PwdEnc' '')
if ($pwdPlain) {
    $pwdEnc = ConvertFrom-SecureString -SecureString $pwdSec
    Good '  Password encrypted with DPAPI. / 密码已用 DPAPI 加密。'
} elseif ($pwdEnc) {
    Warn '  Reusing the previously saved password. / 沿用上一次保存的密码。'
} else {
    Bad '  No password -- automatic login is impossible. / 没有密码，无法自动登录。'
}

# ==================== 4. Save config ====================
Head '4/5  Save config / 保存配置'
$extraObj = $null
$extraOld = Get-Cfg2 $old 'ExtraFields' $null
$extraIn = ''
if ($extraOld) {
    $kv = @()
    foreach ($p in $extraOld.PSObject.Properties) { $kv += ($p.Name + '=' + $p.Value) }
    $extraIn = ($kv -join '&')
}
$extraIn = Ask '  Extra fixed fields (a=1&b=2; empty = none)' $extraIn
if ($extraIn) {
    $h = @{}
    foreach ($kv in $extraIn.Split('&')) {
        if ($kv -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
    }
    if ($h.Count -gt 0) { $extraObj = $h }
}

$cfgObj = [ordered]@{
    '_comment'        = 'Generated by Setup-CampusNet.ps1. PwdEnc is DPAPI ciphertext: it only decrypts for the same Windows user on the same machine. NEVER commit this file.'
    'LoginUrl'        = $portalUrl
    'PortalUrl'       = ''
    'Mode'            = $mode
    'UserField'       = $userField
    'PwdField'        = $pwdField
    'PwdTransform'    = $pwdTf
    'PwdTemplate'     = $pwdTpl
    'TokenRegex'      = [string](Get-Cfg2 $old 'TokenRegex' '')
    'ExtraFields'     = $extraObj
    'User'            = $user
    'UserSuffix'      = $userSuffix
    'PwdEnc'          = $pwdEnc
    'PwdPlain'        = ''
    'WifiProfile'     = $wifiProfile
    'SuccessTestUrl'  = [string](Get-Cfg2 $old 'SuccessTestUrl' 'http://connect.rom.miui.com/generate_204')
    'SuccessStatus'   = 204
    'SuccessRegex'    = ''
    'AllowInvalidCert' = [bool]$allowBad
    'RetryCount'      = 6
    'RetryDelaySec'   = 10
    'Headers'         = $null
}
Set-Content -LiteralPath $ConfigPath -Value ($cfgObj | ConvertTo-Json -Depth 6) -Encoding UTF8
Good ('Written / 已写入: ' + $ConfigPath)
Warn 'Keep this file out of git -- it holds your encrypted password. (Already in .gitignore.)'

if ($Probe) {
    Say ''
    Good 'Probe-only run finished. / 探测模式结束。'
    exit 0
}

# ==================== 5. Test + autostart ====================
Head '5/5  Test run + autostart / 试跑 & 开机自启'
Say 'Running one real login attempt now ... / 现在强制跑一次认证...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MainScript -Force
$rc = $LASTEXITCODE
if ($rc -eq 0) { Good 'Result: OK / 试跑结果: 成功' }
else { Warn ('Result: FAILED (exit=' + $rc + ') -- see 连网日志.txt / 试跑未成功') }

Say ''
if (-not (Ask-Yes 'Install autostart? / 要装开机自启吗？' $true)) {
    Say 'Skipped. Re-run .\Setup-CampusNet.ps1 anytime. / 已跳过。'
    exit 0
}

$argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MainScript + '"'
$installed = $false

if ($isAdmin) {
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine -WorkingDirectory $Root
        $t1 = New-ScheduledTaskTrigger -AtLogOn
        try { $t1.Delay = 'PT20S' } catch { }
        $triggers = @($t1)
        if (Ask-Yes '  Add a keep-alive trigger every 10 min? / 再加一个每 10 分钟保活触发器？' $true) {
            $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                  -RepetitionInterval (New-TimeSpan -Minutes 10) `
                  -RepetitionDuration (New-TimeSpan -Days 3650)
            $triggers += $t2
        }
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
                    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 2)
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
                     -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
            -Principal $principal `
            -Description 'Auto-login to the campus network portal after logon (installed by Setup-CampusNet.ps1)' -Force | Out-Null
        $installed = $true
        Good ('Scheduled task registered / 已注册计划任务: ' + $TaskName)
    } catch {
        Warn ('Scheduled task failed: ' + $_.Exception.Message)
        Warn 'Falling back to a Startup shortcut. / 改用启动文件夹方案。'
    }
} else {
    Say 'Not elevated -- using a Startup shortcut (no watchdog). / 未提权，改用启动文件夹（无保活触发器）。'
}

if (-not $installed) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($StartupLnk)
        $lnk.TargetPath       = 'powershell.exe'
        $lnk.Arguments        = $argLine
        $lnk.WorkingDirectory = $Root
        $lnk.WindowStyle      = 7
        $lnk.Description      = 'Auto-login to the campus network portal'
        $lnk.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws)
        $installed = $true
        Good ('Startup shortcut created / 已创建启动项: ' + $StartupLnk)
    } catch {
        Bad ('Startup shortcut failed: ' + $_.Exception.Message)
        Warn 'Try: run this wizard from an elevated PowerShell. / 请用管理员身份重开 PowerShell 再跑一次。'
    }
}

Say ''
if ($installed) {
    Good 'Done. Autostart is installed. / 装好了，以后登录后约 20 秒自动连。'
    if ($isAdmin) {
        Say  '  Run the task now / 立刻手动测: Start-ScheduledTask -TaskName ''CampusNet-Autoconnect'''
    }
    Say  '  Remove autostart / 取消自启: .\Setup-CampusNet.ps1 -Uninstall'
} else {
    Warn 'Autostart was NOT installed, but the script itself works.'
    Warn 'You can still run .\Connect-CampusNet.ps1 manually. / 自启没装成功，脚本本身可用。'
}
