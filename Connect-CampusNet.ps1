<#
  Connect-CampusNet.ps1 -- Auto-login to a campus network portal after boot
  校园网 Portal 自动认证脚本
  ================================================================
  EN  Replays the portal login form you would normally fill in by hand.
      It does NOT crack, bypass, or weaken any authentication.
  CN  把平时在浏览器里手填的那张登录表单自动填一遍、自动提交。
      不破解、不绕过任何认证机制。

  Usage / 用法
    .\Connect-CampusNet.ps1              # normal: exit early if already online
    .\Connect-CampusNet.ps1 -Force       # always run one login attempt
    .\Connect-CampusNet.ps1 -Probe       # human-readable portal detection
    .\Connect-CampusNet.ps1 -ProbeJson   # machine-readable detection (for Setup)
    .\Connect-CampusNet.ps1 -Quiet -NoLog

  Exit codes / 退出码
    0 = success or already online
    1 = authentication failed
    2 = config file missing
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [switch]$Probe,
    [switch]$ProbeJson,
    [switch]$Quiet,
    [switch]$NoLog
)

$ErrorActionPreference = 'Continue'

# ==================== Constants / 常量 ====================
$script:Root        = $PSScriptRoot
$script:UserAgent   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$script:CookieJar   = New-Object System.Net.CookieContainer
$script:LogPath     = $null
$script:MaxLogBytes = 512KB
$script:Secrets     = New-Object System.Collections.ArrayList
$script:Version     = '1.1.0'

# -ProbeJson is meant to be piped into ConvertFrom-Json: keep stdout pure JSON
if ($ProbeJson) { $Quiet = $true; $NoLog = $true }

# ==================== Logging / 日志 ====================
function Hide-Secret {
    param([string]$Text)
    if (-not $Text) { return $Text }
    foreach ($s in $script:Secrets) {
        if ($s -and $s.Length -ge 3) { $Text = $Text.Replace($s, '***') }
    }
    return $Text
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $Message = Hide-Secret $Message
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'OK'    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line }
        }
    }
    if ($NoLog -or (-not $script:LogPath)) { return }
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and
            ((Get-Item -LiteralPath $script:LogPath).Length -gt $script:MaxLogBytes)) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ==================== Config / 配置 ====================
function Get-Cfg {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    if ($p.Value -is [string] -and $p.Value -eq '') { return $Default }
    return $p.Value
}

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Log ("Failed to read config / 读取配置失败: {0}" -f $_.Exception.Message) 'ERROR'
        return $null
    }
}

# ==================== HTTP ====================
function Convert-BytesToText {
    param([byte[]]$Bytes, [string]$ContentType)
    $cs = $null
    if ($ContentType -and $ContentType -match 'charset\s*=\s*"?([\w\-]+)') { $cs = $Matches[1] }
    if (-not $cs) {
        $len = [Math]::Min(2048, $Bytes.Length)
        if ($len -gt 0) {
            $head = [Text.Encoding]::ASCII.GetString($Bytes, 0, $len)
            if ($head -match 'charset\s*=\s*["'']?([\w\-]+)') { $cs = $Matches[1] }
        }
    }
    if ($cs) {
        if ($cs -match '^(?i)(gb2312|gbk|gb18030)$') { $cs = 'GB18030' }
        try { return [Text.Encoding]::GetEncoding($cs).GetString($Bytes) } catch { }
    }
    $utf8 = [Text.Encoding]::UTF8.GetString($Bytes)
    if ($utf8 -match [char]0xFFFD) {
        try { return [Text.Encoding]::GetEncoding(936).GetString($Bytes) } catch { }
    }
    return $utf8
}

# Some campus portals use self-signed / expired certificates.
# Only enabled when the config explicitly asks for it.
function Enable-SkipCertCheck {
    try {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($sender, $cert, $chain, $errors)
            return $true
        }
        Write-Log 'TLS certificate validation is DISABLED (AllowInvalidCert=true).' 'WARN'
    } catch {
        Write-Log ("Could not disable cert validation / 无法关闭证书校验: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Invoke-Http {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Method = 'GET',
        [string]$Body,
        [string]$ContentType = 'application/x-www-form-urlencoded',
        [int]$TimeoutSec = 12,
        [switch]$AllowRedirect,
        $ExtraHeaders
    )
    if ($Url -notmatch '^https?://') { $Url = 'http://' + $Url }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor `
            [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch { }

    $req = $null
    try { $req = [System.Net.HttpWebRequest]::Create($Url) } catch {
        Write-Log ("Invalid URL / URL 非法: {0}" -f $Url) 'WARN'; return $null
    }
    $req.Method            = $Method
    $req.Timeout           = $TimeoutSec * 1000
    $req.ReadWriteTimeout  = $TimeoutSec * 1000
    $req.AllowAutoRedirect = [bool]$AllowRedirect
    $req.MaximumAutomaticRedirections = 10
    $req.CookieContainer   = $script:CookieJar
    $req.UserAgent         = $script:UserAgent
    $req.Accept            = '*/*'
    if ($ExtraHeaders -and $ExtraHeaders.PSObject) {
        foreach ($p in $ExtraHeaders.PSObject.Properties) {
            try { $req.Headers[$p.Name] = [string]$p.Value } catch { }
        }
    }
    if ($Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType   = $ContentType
        $req.ContentLength = $bytes.Length
        try {
            $st = $req.GetRequestStream()
            $st.Write($bytes, 0, $bytes.Length)
            $st.Close()
        } catch { Write-Log ("Request body failed / 请求发送失败: {0}" -f $_.Exception.Message) 'WARN'; return $null }
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else {
            Write-Log ("Request failed / 请求失败 {0} -> {1}" -f $Url, $_.Exception.Message) 'WARN'
            return $null
        }
    } catch {
        Write-Log ("Request error / 请求异常 {0} -> {1}" -f $Url, $_.Exception.Message) 'WARN'
        return $null
    }

    $status = 0; $loc = ''; $ctype = ''
    try { $status = [int]$resp.StatusCode } catch { }
    try { $loc = [string]$resp.Headers['Location'] } catch { }
    try { $ctype = [string]$resp.ContentType } catch { }

    $raw = $null
    try {
        $rs  = $resp.GetResponseStream()
        $ms  = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while ($true) {
            $n = $rs.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $raw = $ms.ToArray()
        $ms.Close(); $rs.Close()
    } catch { }
    try { $resp.Close() } catch { }

    $text = ''
    if ($raw -and $raw.Length -gt 0) { $text = Convert-BytesToText -Bytes $raw -ContentType $ctype }

    return [pscustomobject]@{
        Url = $Url; Status = $status; Location = $loc
        ContentType = $ctype; Text = $text
    }
}

# The outbound source IP of this machine -- Dr.COM style portals want it as
# `wlanuserip`, and it changes with every DHCP lease, so it cannot be hardcoded
# into the config. Available to ExtraFields as the {localip} placeholder.
function Get-LocalIPv4 {
    param([string]$TargetHost)
    try {
        if (-not $TargetHost) { $TargetHost = '10.0.0.1' }
        $sock = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        try {
            $sock.Connect($TargetHost, 80)   # UDP connect sends nothing; it just picks a route
            return ([System.Net.IPEndPoint]$sock.LocalEndPoint).Address.ToString()
        } finally { $sock.Close() }
    } catch { return '' }
}

# ==================== Online check / 联网判定 ====================
function Test-Online {
    param($Cfg)
    $url = Get-Cfg $Cfg 'SuccessTestUrl' 'http://connect.rom.miui.com/generate_204'
    $r = Invoke-Http -Url $url -TimeoutSec 8
    if (-not $r) { return $false }
    if ($r.Location) { return $false }                       # redirected => a portal is intercepting
    if ($r.Status -ge 300 -and $r.Status -lt 400) { return $false }
    $want = Get-Cfg $Cfg 'SuccessStatus' 204
    $rx   = Get-Cfg $Cfg 'SuccessRegex' $null
    if ($rx -and $r.Text -match $rx) { return $true }
    if ([int]$r.Status -eq [int]$want) { return $true }
    return $false
}

# ==================== Portal detection / 门户探测 ====================
# A plain http->https upgrade or CDN redirect is not a portal intercept.
function Test-TrivialRedirect {
    param([string]$From, [string]$To)
    $fh = ''
    try { $fh = ([Uri]$From).Host } catch { }
    $th = ''
    try { $th = ([Uri]$To).Host } catch { return $true }
    if (-not $th) { return $true }
    if ($fh -and $fh -eq $th) { return $true }
    if ($th -match '(?i)cloudflare|akamai|fastly|msftconnecttest|apple\.com|firefox\.com|miui\.com|google\.com|gstatic|microsoft\.com') { return $true }
    return $false
}

# Does this page actually look like a campus login page?
function Test-PortalPage {
    param([string]$Url)
    $r = Invoke-Http -Url $Url -TimeoutSec 8
    if (-not $r) { return $false }
    if ($r.Text -match '(?is)<input[^>]+type\s*=\s*["'']?password') { return $true }
    if ($r.Text -match '(?is)<form' -and $r.Text -match '认证|登录|登陆|上网|校园网|portal|srun|drcom|netkeeper|注销') { return $true }
    return $false
}

function Find-PortalUrl {
    param($Cfg)

    # An explicitly configured portal wins.
    $fixed = Get-Cfg $Cfg 'PortalUrl' $null
    if ($fixed) {
        if (Test-PortalPage -Url $fixed) { return $fixed }
        Write-Log 'Configured portal page has no parseable form (maybe JS-rendered); using it anyway.' 'WARN'
        return $fixed
    }

    $list = @('http://connect.rom.miui.com/generate_204',
              'http://www.msftconnecttest.com/connecttest.txt',
              'http://detectportal.firefox.com/success.txt',
              'http://captive.apple.com/hotspot-detect.html')

    $cands = New-Object System.Collections.ArrayList
    foreach ($u in $list) {
        $r = Invoke-Http -Url $u -TimeoutSec 6
        if (-not $r) { continue }
        if ($r.Location -and $r.Location -match '^https?://') {
            if (Test-TrivialRedirect -From $u -To $r.Location) {
                Write-Log ("Ignoring ordinary redirect / 忽略普通跳转: {0} -> {1}" -f $u, $r.Location)
            } else {
                [void]$cands.Add($r.Location)
            }
        }
        # Some portals answer 200 with the login page inline instead of redirecting.
        elseif ($r.Status -eq 200 -and $r.Text -match '(?is)<input[^>]+type\s*=\s*["'']?password') {
            [void]$cands.Add($u)
        }
    }

    foreach ($c in $cands) {
        if (Test-PortalPage -Url $c) { return $c }
        Write-Log ("Candidate rejected (not a login page) / 候选被排除: {0}" -f $c) 'WARN'
    }
    return $null
}

# ==================== Form parsing / 表单解析 ====================
function Get-PageForm {
    param([string]$Html, [string]$PageUrl)
    $result = [pscustomobject]@{
        Action  = $PageUrl
        Method  = 'POST'
        Fields  = (New-Object 'System.Collections.Specialized.OrderedDictionary')
        Types   = (New-Object 'System.Collections.Specialized.OrderedDictionary')
        Options = (New-Object 'System.Collections.Specialized.OrderedDictionary')
    }
    if (-not $Html) { return $result }

    $forms = [regex]::Matches($Html, '(?is)<form\b[^>]*>.*?</form>')
    $chosen = $null
    foreach ($f in $forms) {
        if ($f.Value -match '(?is)type\s*=\s*["'']?password') { $chosen = $f.Value; break }
    }
    if (-not $chosen) {
        if ($forms.Count -gt 0) { $chosen = $forms[0].Value } else { return $result }
    }

    $tag = [regex]::Match($chosen, '(?is)^<form\b[^>]*>').Value
    $act = [regex]::Match($tag, '(?is)action\s*=\s*["'']([^"'']*)["'']')
    if ($act.Success -and $act.Groups[1].Value) {
        $a = $act.Groups[1].Value
        if ($a -match '^https?://') { $result.Action = $a }
        elseif ($a -match '^/') {
            $b = [regex]::Match($PageUrl, '^(https?://[^/]+)')
            $result.Action = $b.Groups[1].Value + $a
        } else {
            $b = [regex]::Match($PageUrl, '^(https?://.+/)[^/]*$')
            if ($b.Success) { $result.Action = $b.Groups[1].Value + $a } else { $result.Action = $PageUrl }
        }
    }
    $m = [regex]::Match($tag, '(?is)method\s*=\s*["'']?([a-zA-Z]+)')
    if ($m.Success) { $result.Method = $m.Groups[1].Value.ToUpper() }

    # ---- <input> ----
    # Radio buttons share one name. The old parser kept "the last value seen",
    # which silently submits the WRONG carrier/ISP choice. A radio group is now
    # resolved to its checked member (or its first member), and every option is
    # recorded so -Probe can show them.
    foreach ($i in [regex]::Matches($chosen, '(?is)<input\b[^>]*>')) {
        $t  = $i.Value
        $nm = [regex]::Match($t, '(?is)name\s*=\s*["'']([^"'']*)["'']')
        if (-not $nm.Success) { continue }
        $name = $nm.Groups[1].Value
        $vl   = [regex]::Match($t, '(?is)value\s*=\s*["'']([^"'']*)["'']')
        $ty   = [regex]::Match($t, '(?is)type\s*=\s*["'']([^"'']*)["'']')
        $val  = ''; $typ = 'text'
        if ($vl.Success) { $val = $vl.Groups[1].Value }
        if ($ty.Success) { $typ = $ty.Groups[1].Value.ToLower() }
        $checked = [bool]($t -match '(?i)\bchecked\b')

        if ($typ -eq 'radio') {
            if (-not $result.Options.Contains($name)) {
                $result.Options[$name] = New-Object System.Collections.ArrayList
                $result.Types[$name]   = 'radio'
                $result.Fields[$name]  = $val
            }
            [void]$result.Options[$name].Add($val)
            if ($checked) { $result.Fields[$name] = $val }
            continue
        }
        if ($typ -eq 'checkbox') {
            if (-not $result.Options.Contains($name)) {
                $result.Options[$name] = New-Object System.Collections.ArrayList
                $result.Types[$name]   = 'checkbox'
            }
            [void]$result.Options[$name].Add($val)
            if ($checked) { $result.Fields[$name] = $val }
            continue
        }
        $result.Fields[$name] = $val
        $result.Types[$name]  = $typ
    }

    # ---- <select> ----
    # A carrier / ISP dropdown lives here. The old parser ignored <select>
    # completely, so that field was never submitted at all.
    foreach ($s in [regex]::Matches($chosen, '(?is)<select\b[^>]*>.*?</select>')) {
        $nm = [regex]::Match($s.Value, '(?is)<select\b[^>]*name\s*=\s*["'']([^"'']*)["'']')
        if (-not $nm.Success) { continue }
        $name = $nm.Groups[1].Value
        $vals = New-Object System.Collections.ArrayList
        $sel  = ''
        foreach ($o in [regex]::Matches($s.Value, '(?is)<option\b[^>]*>.*?</option>')) {
            $ov = [regex]::Match($o.Value, '(?is)value\s*=\s*["'']([^"'']*)["'']')
            if ($ov.Success) { $v = $ov.Groups[1].Value }
            else { $v = ([regex]::Replace($o.Value, '(?is)^<option\b[^>]*>|</option>$', '')).Trim() }
            [void]$vals.Add($v)
            if (($o.Value -match '(?i)\bselected\b') -and (-not $sel)) { $sel = $v }
        }
        if ($vals.Count -gt 0) {
            if (-not $sel) { $sel = [string]$vals[0] }
            $result.Fields[$name]  = $sel
            $result.Types[$name]   = 'select'
            $result.Options[$name] = $vals
        }
    }
    return $result
}

# Best-effort guess of which fields hold the account, the password,
# and the carrier / ISP selector.
function Get-FieldGuess {
    param($Form)
    $user = ''; $pwd = ''; $carrier = ''
    if (-not $Form) { return [pscustomobject]@{ User = ''; Pwd = ''; Carrier = '' } }

    foreach ($n in $Form.Fields.Keys) {
        $t = [string]$Form.Types[$n]
        if (-not $pwd -and $t -match '(?i)password') { $pwd = $n }
    }
    foreach ($n in $Form.Fields.Keys) {
        $t = [string]$Form.Types[$n]
        if ($t -match '(?i)password|hidden|submit|button|checkbox|radio|select') { continue }
        if ($n -match '(?i)user|name|account|login|id$' -or $n -match '学号|账号|帐号|用户名') { $user = $n; break }
    }
    if (-not $pwd) {
        foreach ($n in $Form.Fields.Keys) {
            if ($n -match '(?i)pwd|pass') { $pwd = $n; break }
        }
    }
    if (-not $user) {
        foreach ($n in $Form.Fields.Keys) {
            $t = [string]$Form.Types[$n]
            if ($t -match '(?i)^(text|email|tel)$') { $user = $n; break }
        }
    }

    # Carrier / ISP selector: a radio group or a dropdown with a telling name.
    foreach ($n in $Form.Options.Keys) {
        $t = [string]$Form.Types[$n]
        if ($t -notmatch '(?i)radio|select') { continue }
        if ($n -match '(?i)yys|isp|carrier|domain|nettype|operator|service|line|服务|运营商|线路|类型') { $carrier = $n; break }
    }
    if (-not $carrier) {
        foreach ($n in $Form.Options.Keys) {
            $t = [string]$Form.Types[$n]
            if ($t -notmatch '(?i)radio|select') { continue }
            $c = $Form.Options[$n].Count
            if ($c -ge 2 -and $c -le 12) { $carrier = $n; break }
        }
    }
    return [pscustomobject]@{ User = $user; Pwd = $pwd; Carrier = $carrier }
}

# ==================== Password transforms / 密码变形 ====================
function Get-Md5Hex {
    param([string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    $md5.Clear()
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-PwdValue {
    param([string]$Plain, [string]$Kind)
    if (-not $Kind) { $Kind = 'plain' }
    switch ($Kind.ToLower()) {
        'md5'    { return (Get-Md5Hex $Plain) }
        'base64' { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Plain)) }
        default  { return $Plain }
    }
}

function Expand-PwdTemplate {
    param([string]$Template, [string]$Plain, [string]$User, [string]$Token = '')
    if (-not $Template) { $Template = '{pwd}' }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Plain))
    $s = $Template
    $s = $s.Replace('{pwd}',   (Get-PwdValue -Plain $Plain -Kind (Get-Cfg $script:Cfg 'PwdTransform' 'plain')))
    $s = $s.Replace('{plain}', $Plain)
    $s = $s.Replace('{b64}',   $b64)
    $s = $s.Replace('{b64d}',  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($b64)))
    $s = $s.Replace('{md5}',   (Get-Md5Hex $Plain))
    $s = $s.Replace('{user}',  $User)
    $s = $s.Replace('{token}', $Token)
    return $s
}

function Get-PlainPassword {
    param([string]$Enc, [string]$PlainField)
    if ($PlainField) { return $PlainField }
    if (-not $Enc) { return '' }
    try {
        $sec = ConvertTo-SecureString -String $Enc -ErrorAction Stop
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Log 'Password decryption failed. DPAPI ciphertext only decrypts for the SAME Windows user on the SAME machine. Re-run Setup-CampusNet.ps1. / 密码解密失败：DPAPI 密文只能由当初加密的同一 Windows 用户在同一台电脑上解开，请重跑设置向导。' 'ERROR'
        return ''
    }
}

# ==================== URL / form building ====================
function Add-OrSet-Query {
    param([string]$Url, $Pairs)
    $base = $Url; $q = ''
    $i = $Url.IndexOf('?')
    if ($i -ge 0) { $base = $Url.Substring(0, $i); $q = $Url.Substring($i + 1) }
    $parts = New-Object System.Collections.ArrayList
    $seen  = @{}
    if ($q) {
        foreach ($kv in $q.Split('&')) {
            if (-not $kv) { continue }
            $k = $kv; $eq = $kv.IndexOf('=')
            if ($eq -ge 0) { $k = $kv.Substring(0, $eq) }
            $dk = $k
            try { $dk = [Uri]::UnescapeDataString($k) } catch { }
            if ($Pairs.Contains($dk)) {
                [void]$parts.Add(([Uri]::EscapeDataString($dk) + '=' + [Uri]::EscapeDataString([string]$Pairs[$dk])))
                $seen[$dk] = $true
            } else { [void]$parts.Add($kv) }
        }
    }
    foreach ($k in $Pairs.Keys) {
        if (-not $seen.ContainsKey($k)) {
            [void]$parts.Add(([Uri]::EscapeDataString($k) + '=' + [Uri]::EscapeDataString([string]$Pairs[$k])))
        }
    }
    if ($parts.Count -eq 0) { return $base }
    return $base + '?' + ($parts -join '&')
}

function Build-FormBody {
    param($Fields)
    $parts = @()
    foreach ($k in $Fields.Keys) {
        $v = [Uri]::EscapeDataString([string]$Fields[$k])
        $v = $v.Replace('%20', '+')
        $parts += ([Uri]::EscapeDataString([string]$k) + '=' + $v)
    }
    return ($parts -join '&')
}

# Substitute placeholders into a captured login URL (Mode = Url).
# Values are URL-encoded, because they land inside a query string.
function Expand-LoginUrl {
    param(
        [string]$Template,
        [string]$User,
        [string]$Plain,
        [string]$PwdValue,
        [string]$Token = '',
        [string]$LocalIp = ''
    )
    $s = $Template
    $s = $s.Replace('{user}',    [Uri]::EscapeDataString($User))
    $s = $s.Replace('{userraw}', $User)
    $s = $s.Replace('{pwd}',     [Uri]::EscapeDataString($PwdValue))
    $s = $s.Replace('{plain}',   [Uri]::EscapeDataString($Plain))
    $s = $s.Replace('{b64}',     [Uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Plain))))
    $s = $s.Replace('{md5}',     (Get-Md5Hex $Plain))
    $s = $s.Replace('{token}',   [Uri]::EscapeDataString($Token))
    $s = $s.Replace('{localip}', $LocalIp)
    return $s
}

# ==================== Login / 认证主逻辑 ====================
function Invoke-CampusLogin {
    param($Cfg)
    $user  = [string](Get-Cfg $Cfg 'User' '')
    $plain = Get-PlainPassword -Enc ([string](Get-Cfg $Cfg 'PwdEnc' '')) -PlainField ([string](Get-Cfg $Cfg 'PwdPlain' ''))
    if (-not $user -or -not $plain) {
        Write-Log 'Account or password is empty. Run Setup-CampusNet.ps1 first. / 账号或密码为空，请先运行设置向导。' 'ERROR'
        return $false
    }
    [void]$script:Secrets.Add($plain)

    $portal = [string](Get-Cfg $Cfg 'LoginUrl' '')
    if (-not $portal) { $portal = Find-PortalUrl -Cfg $Cfg }
    if (-not $portal) {
        Write-Log 'No login portal detected (link/Wi-Fi down, or the network is simply fine). / 没探测到认证门户。' 'WARN'
        return $false
    }
    Write-Log ("Portal / 门户: {0}" -f $portal)

    $userField = [string](Get-Cfg $Cfg 'UserField' 'username')
    $pwdField  = [string](Get-Cfg $Cfg 'PwdField'  'password')
    $template  = [string](Get-Cfg $Cfg 'PwdTemplate' '{pwd}')
    $mode      = [string](Get-Cfg $Cfg 'Mode' 'Auto')
    $headers   = Get-Cfg $Cfg 'Headers' $null

    # Dr.COM / 城市热点 style portals select the carrier by APPENDING A SUFFIX to the
    # account (校园联通 -> 学号@lt). It is a per-user choice, so it cannot be parsed
    # out of the page; it has to come from the config.
    $suffix = [string](Get-Cfg $Cfg 'UserSuffix' '')
    $userSubmit = $user
    if ($suffix) {
        $userSubmit = $user + $suffix
        Write-Log ("Account suffix / 运营商后缀: {0}  ->  {1}" -f $suffix, $userSubmit)
    }

    $page = Invoke-Http -Url $portal -TimeoutSec 10
    $token = ''
    if ($page -and $page.Text) {
        $trx = Get-Cfg $Cfg 'TokenRegex' $null
        if ($trx) {
            $tm = [regex]::Match($page.Text, $trx)
            if ($tm.Success -and $tm.Groups.Count -gt 1) { $token = $tm.Groups[1].Value }
        }
    }
    $pwdValue = Expand-PwdTemplate -Template $template -Plain $plain -User $user -Token $token
    # Redact the transformed password too: base64/md5 forms are trivially reversible,
    # so if a portal echoes them back into an error page they must not reach the log.
    if ($pwdValue -and $pwdValue -ne $plain -and $pwdValue -ne $user -and $pwdValue.Length -ge 4) {
        [void]$script:Secrets.Add($pwdValue)
    }

    # Auto:
    #   LoginUrl contains {placeholders}      -> Url   (replay a captured request verbatim)
    #   the portal URL already carries params -> Query
    #   otherwise                             -> Form
    $realMode = $mode
    if ($mode -eq 'Auto') {
        if ($portal -match '\{[a-zA-Z]+\}') { $realMode = 'Url' }
        elseif ($portal -match '\?.+=')     { $realMode = 'Query' }
        else                                { $realMode = 'Form' }
    }
    Write-Log ("Login mode / 登录方式: {0}" -f $realMode)

    $extra = Get-Cfg $Cfg 'ExtraFields' $null
    $extraPairs = @{}
    if ($extra) {
        # Values may use {localip} / {user} -- e.g. Dr.COM needs wlanuserip=<this PC's IP>.
        $localIp = ''
        if ($extra.PSObject.Properties.Name -contains 'wlanuserip' -or
            (($extra | ConvertTo-Json -Depth 3) -match '\{localip\}')) {
            try { $localIp = Get-LocalIPv4 -TargetHost ([Uri]$portal).Host } catch { $localIp = Get-LocalIPv4 }
        }
        foreach ($p in $extra.PSObject.Properties) {
            $v = [string]$p.Value
            $v = $v.Replace('{localip}', $localIp).Replace('{user}', $user)
            $extraPairs[$p.Name] = $v
        }
    }

    if ($realMode -eq 'Url') {
        # Replay a request you captured yourself (F12 -> Network -> Copy as cURL).
        # This is the escape hatch for portals whose form is built by JavaScript:
        # paste the real request URL, replace only the account / password / IP
        # values with placeholders, and the script replays it on every run.
        $localIp = ''
        try { $localIp = Get-LocalIPv4 -TargetHost ([Uri]$portal).Host } catch { $localIp = '' }
        $target = Expand-LoginUrl -Template $portal -User $userSubmit -Plain $plain `
                                  -PwdValue $pwdValue -Token $token -LocalIp $localIp
        Write-Log 'Replaying captured login URL (GET) ... / 重放抓包得到的登录请求 (GET)'
        $r = Invoke-Http -Url $target -TimeoutSec 12 -ExtraHeaders $headers
    }
    elseif ($realMode -eq 'Query') {
        $pairs = @{}
        foreach ($k in $extraPairs.Keys) { $pairs[$k] = $extraPairs[$k] }
        $pairs[$userField] = $userSubmit
        $pairs[$pwdField]  = $pwdValue
        $target = Add-OrSet-Query -Url $portal -Pairs $pairs
        Write-Log 'Submitting login (GET) ... / 提交认证请求 (GET)'
        $r = Invoke-Http -Url $target -TimeoutSec 12 -ExtraHeaders $headers
    } else {
        $form = Get-PageForm -Html $page.Text -PageUrl $portal
        Write-Log ("Form action: {0}" -f $form.Action)
        $fields = New-Object 'System.Collections.Specialized.OrderedDictionary'
        foreach ($k in $form.Fields.Keys) { $fields[$k] = $form.Fields[$k] }
        foreach ($k in $extraPairs.Keys) { $fields[$k] = $extraPairs[$k] }
        $fields[$userField] = $userSubmit
        $fields[$pwdField]  = $pwdValue
        $body = Build-FormBody -Fields $fields
        Write-Log 'Submitting login (POST) ... / 提交认证请求 (POST)'
        if ($form.Method -eq 'GET') {
            $target = Add-OrSet-Query -Url $form.Action -Pairs $fields
            $r = Invoke-Http -Url $target -TimeoutSec 12 -ExtraHeaders $headers
        } else {
            $r = Invoke-Http -Url $form.Action -Method 'POST' -Body $body -TimeoutSec 12 -ExtraHeaders $headers
        }
    }

    if (-not $r) { Write-Log 'No response to the login request. / 认证请求没有响应' 'WARN'; return $false }
    Write-Log ("Login response HTTP {0}" -f $r.Status)
    if ($r.Text) {
        $brief = $r.Text -replace '(?s)\s+', ' '
        if ($brief.Length -gt 160) { $brief = $brief.Substring(0, 160) }
        Write-Log ("Response / 响应内容: {0}" -f $brief)
    }

    Start-Sleep -Seconds 2
    if (Test-Online -Cfg $Cfg) { return $true }
    Start-Sleep -Seconds 3
    return (Test-Online -Cfg $Cfg)
}

# ==================== Wi-Fi pre-connect ====================
function Connect-WifiProfile {
    param([string]$Profile)
    if (-not $Profile) { return }
    try {
        $info = (netsh wlan show interfaces 2>&1 | Out-String)
        if ($info -match '已连接|connected') {
            Write-Log ("Wi-Fi already connected / Wi-Fi 已连接: {0}" -f $Profile)
            return
        }
        Write-Log ("Connecting Wi-Fi / 尝试连接 Wi-Fi: {0}" -f $Profile)
        netsh wlan connect name="$Profile" 2>&1 | Out-Null
        Start-Sleep -Seconds 8
    } catch {
        Write-Log ("Wi-Fi step failed / Wi-Fi 连接步骤异常: {0}" -f $_.Exception.Message) 'WARN'
    }
}

# ==================== Entry / 入口 ====================
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'campus-net.config.json' }

function Get-ProbeJsonResult {
    param($Cfg, [bool]$Online, [string]$PortalUrl, $Page, $Form)
    $guess = Get-FieldGuess -Form $Form
    $fields = @()
    if ($Form) {
        foreach ($n in $Form.Fields.Keys) {
            $opts = @()
            if ($Form.Options.Contains($n)) {
                $opts = @($Form.Options[$n] | ForEach-Object { [string]$_ })
            }
            $fields += [pscustomobject]@{
                Name    = $n
                Type    = [string]$Form.Types[$n]
                Value   = [string]$Form.Fields[$n]
                Options = $opts
            }
        }
    }
    $guessedMode = 'Form'
    if ($PortalUrl -and $PortalUrl -match '\?.+=') { $guessedMode = 'Query' }
    return [pscustomobject]@{
        Version           = $script:Version
        Online            = $Online
        PortalUrl         = [string]$PortalUrl
        PortalReachable   = [bool]($Page -ne $null)
        FormAction        = $(if ($Form) { [string]$Form.Action } else { '' })
        FormMethod        = $(if ($Form) { [string]$Form.Method } else { '' })
        Fields            = $fields
        GuessUserField    = [string]$guess.User
        GuessPwdField     = [string]$guess.Pwd
        GuessCarrierField = [string]$guess.Carrier
        GuessedMode       = $guessedMode
    }
}

$cfg = Read-Config -Path $ConfigPath
if ($ProbeJson -and -not $cfg) { $cfg = New-Object psobject }
if (-not $cfg) {
    if (-not $Probe) {
        Write-Host 'Config not found. Run: .\Setup-CampusNet.ps1 / 找不到配置文件，请先运行设置向导' -ForegroundColor Red
        exit 2
    }
    $cfg = New-Object psobject
}
$script:Cfg     = $cfg
$script:LogPath = [string](Get-Cfg $cfg 'LogFile' (Join-Path $script:Root '连网日志.txt'))

if ([bool](Get-Cfg $cfg 'AllowInvalidCert' $false)) { Enable-SkipCertCheck }

# ---------- Probe: machine readable ----------
if ($ProbeJson) {
    $online = Test-Online -Cfg $cfg
    $portal = ''
    $page   = $null
    $form   = $null
    if (-not $online) {
        $portal = Find-PortalUrl -Cfg $cfg
        if ($portal) {
            $page = Invoke-Http -Url $portal -TimeoutSec 10
            if ($page) { $form = Get-PageForm -Html $page.Text -PageUrl $portal }
        }
    }
    (Get-ProbeJsonResult -Cfg $cfg -Online $online -PortalUrl $portal -Page $page -Form $form) |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# ---------- Probe: human readable ----------
if ($Probe) {
    Write-Log '=== Portal probe / 门户探测模式 ==='
    $p = Find-PortalUrl -Cfg $cfg
    if (-not $p) {
        if (Test-Online -Cfg $cfg) {
            Write-Log 'No portal redirect, and the network is already up. / 没有门户跳转，且当前网络已通（无需认证）。' 'OK'
            exit 0
        }
        Write-Log 'Not online and no portal seen: Wi-Fi may be down, or the school requires a client app. / 当前不通，也没看到门户。' 'WARN'
        exit 1
    }
    Write-Log ("Portal / 门户地址: {0}" -f $p) 'OK'
    $page = Invoke-Http -Url $p -TimeoutSec 10
    if ($page) {
        Write-Log ("Page HTTP {0}, length {1}" -f $page.Status, $page.Text.Length)
        $form = Get-PageForm -Html $page.Text -PageUrl $p
        $guess = Get-FieldGuess -Form $form
        Write-Log ("Form action = {0} , method = {1}" -f $form.Action, $form.Method)
        if ($form.Fields.Count -gt 0) {
            Write-Log 'Form fields / 表单字段：'
            foreach ($k in $form.Fields.Keys) {
                Write-Log ("    {0} (type={1}) = {2}" -f $k, $form.Types[$k], $form.Fields[$k])
                if ($form.Options.Contains($k)) {
                    Write-Log ("        可选项: {0}" -f (@($form.Options[$k]) -join ' | '))
                }
            }
            Write-Log ("Guessed user field / 推测账号字段: {0}" -f $guess.User)
            Write-Log ("Guessed password field / 推测密码字段: {0}" -f $guess.Pwd)
            if ($guess.Carrier) {
                Write-Log ("Guessed carrier field / 推测运营商字段: {0}  <- 用 ExtraFields 指定它的值" -f $guess.Carrier) 'WARN'
            }
        } else {
            Write-Log '(no <input> found -- the portal may be JS-rendered) / 没解析出 input 字段' 'WARN'
        }
        $dump = Join-Path $script:Root '门户探测结果.txt'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('Portal / 门户地址: ' + $p)
        [void]$sb.AppendLine('Form action: ' + $form.Action)
        [void]$sb.AppendLine('Form method: ' + $form.Method)
        [void]$sb.AppendLine('--- Fields / 字段 ---')
        foreach ($k in $form.Fields.Keys) {
            [void]$sb.AppendLine(($k + ' (type=' + $form.Types[$k] + ') = ' + $form.Fields[$k]))
            if ($form.Options.Contains($k)) {
                [void]$sb.AppendLine('    options: ' + (@($form.Options[$k]) -join ' | '))
            }
        }
        [void]$sb.AppendLine('--- Raw HTML / 原始 HTML ---')
        [void]$sb.AppendLine($page.Text)
        Set-Content -LiteralPath $dump -Value $sb.ToString() -Encoding UTF8
        Write-Log ("Full page written to / 已写入: {0}" -f $dump) 'OK'
    }
    exit 0
}

# ---------- Normal run ----------
$retry = [int](Get-Cfg $cfg 'RetryCount' 6)
$delay = [int](Get-Cfg $cfg 'RetryDelaySec' 10)

Connect-WifiProfile -Profile ([string](Get-Cfg $cfg 'WifiProfile' ''))

if (-not $Force) {
    if (Test-Online -Cfg $cfg) {
        Write-Log 'Already online, nothing to do. / 网络已通，无需认证。' 'OK'
        exit 0
    }
}

for ($i = 1; $i -le $retry; $i++) {
    Write-Log ("Attempt {0}/{1} / 第 {0}/{1} 次尝试认证" -f $i, $retry)
    $ok = $false
    try { $ok = Invoke-CampusLogin -Cfg $cfg } catch { Write-Log ("Exception / 异常: {0}" -f $_.Exception.Message) 'ERROR' }
    if ($ok) { Write-Log 'Login OK, network is up. / 认证成功，网络已通。' 'OK'; exit 0 }
    if ($i -lt $retry) { Start-Sleep -Seconds $delay }
}

Write-Log 'Login failed: retry limit reached. / 认证失败：已达最大重试次数。' 'ERROR'
exit 1
