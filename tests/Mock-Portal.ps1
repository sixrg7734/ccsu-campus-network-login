<#
  Mock-Portal.ps1 -- a fake campus portal gateway, for end-to-end testing
  模拟门户：本地假校园网 Portal，用来端到端验证 Connect-CampusNet.ps1
  ================================================================
  It behaves like a real portal gateway / 它模拟一台真实的 Portal 网关:
    GET  /generate_204   not authed -> 302 to /portal?... (with wlanuserip etc.)
                         authed     -> 204
    GET  /portal         returns a login page with a <form>
    GET  /portal?username=..&password=..   Query-style login
    POST /login          Form-style login
    GET  /reset          reset back to "not authed"

  Raw HTTP/1.1 over TcpListener on purpose: HttpListener needs a urlacl entry
  when you are not an administrator, TcpListener never does.
  用 TcpListener 手写 HTTP/1.1：非管理员跑 HttpListener 要配 urlacl，TcpListener 不用。

  Correct credentials default to testuser / testpass123 (see -User / -Pass).
#>
[CmdletBinding()]
param(
    [int]$Port = 18080,
    [int]$MaxSeconds = 180,
    [string]$LogFile,
    [string]$User = 'testuser',
    [string]$Pass = 'testpass123',
    [string]$Suffix = '@lt'
)

$ErrorActionPreference = 'Continue'
$enc = [Text.Encoding]::UTF8
$script:authed = $false

function Write-MockLog {
    param([string]$Text)
    $line = (Get-Date -Format 'HH:mm:ss.fff') + '  ' + $Text
    Write-Host $line
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Send-Response {
    param($Stream, [string]$Status, [string]$Body = '', [string]$Extra = '')
    $bytes = $enc.GetBytes($Body)
    $head = "HTTP/1.1 $Status`r`nServer: mock-portal`r`nConnection: close`r`nContent-Length: $($bytes.Length)`r`n"
    if ($Extra) { $head += $Extra }
    $head += "`r`n"
    $hb = $enc.GetBytes($head)
    try {
        $Stream.Write($hb, 0, $hb.Length)
        if ($bytes.Length -gt 0) { $Stream.Write($bytes, 0, $bytes.Length) }
        $Stream.Flush()
    } catch { }
}

function Get-LoginPage {
    param([string]$Err = '')
    $errHtml = ''
    if ($Err) { $errHtml = '<div class="err">' + $Err + '</div>' }
    # Chinese text on purpose: it also exercises the charset decoding path.
    return @"
<!DOCTYPE html>
<html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<title>校园网认证</title></head>
<body>
<h2>校园网用户认证</h2>
$errHtml
<form name="login" method="post" action="/login">
  <input type="hidden" name="wlanuserip" value="10.5.23.47">
  <input type="hidden" name="wlanacname" value="TESTAC">
  <input type="hidden" name="nasip" value="10.5.255.254">
  <input type="text"     name="username" value="" placeholder="学号">
  <input type="password" name="password" value="" placeholder="密码">
  <input type="submit"   name="submit"   value="登录">
</form>
</body></html>
"@
}

# Dr.COM / 城市热点 style login page (modelled on a real CCSU portal).
# Two things here are deliberately nasty, because real portals are:
#   · the carrier is a RADIO GROUP  -> a naive parser submits the last value
#   · there is also a <select>       -> a parser that only reads <input> drops it
# The checked radio is value "2", which is neither first nor last, so a
# "keeps the last value" bug and a "keeps the first value" bug both fail loudly.
function Get-DrComPage {
    param([string]$Err = '')
    $errHtml = ''
    if ($Err) { $errHtml = '<div class="err">' + $Err + '</div>' }
    return @"
<!DOCTYPE html>
<html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<title>校园网认证</title></head>
<body>
<h2>校园网用户认证</h2>
$errHtml
<form name="login" method="post" action="/eportal/?c=ACSetting&amp;a=Login">
  <input type="hidden" name="wlanuserip" value="10.5.23.47">
  <input type="hidden" name="wlanacname" value="TESTAC">
  <input type="text"     name="DDDDD" value="" placeholder="账号">
  <input type="password" name="upass" value="" placeholder="密码">
  <input type="radio" name="yys" value="1">校园用户
  <input type="radio" name="yys" value="2" checked>校园电信
  <input type="radio" name="yys" value="3">校园联通
  <select name="domain">
    <option value="0">默认</option>
    <option value="1" selected>教学区</option>
    <option value="2">宿舍区</option>
  </select>
  <input type="submit" name="0MKKey" value="登录">
</form>
</body></html>
"@
}

$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
} catch {
    Write-MockLog ('Failed to start / 启动失败: ' + $_.Exception.Message)
    exit 9
}
Write-MockLog ("mock portal listening on http://127.0.0.1:$Port  (credentials $User / $Pass)")

$deadline = (Get-Date).AddSeconds($MaxSeconds)
$buf = New-Object byte[] 16384

while ((Get-Date) -lt $deadline) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue }

    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000

        $ms = New-Object System.IO.MemoryStream
        $all = ''
        $idx = -1
        $guard = 0
        while ($guard -lt 200) {
            $guard++
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $all = $enc.GetString($ms.ToArray())
            $idx = $all.IndexOf("`r`n`r`n")
            if ($idx -ge 0) { break }
        }
        if ($idx -lt 0) { $client.Close(); continue }

        $headerText = $all.Substring(0, $idx)
        $body = $all.Substring($idx + 4)
        $lines = $headerText -split "`r`n"
        $req = $lines[0].Split(' ')
        $method = $req[0]
        $target = $req[1]

        $clen = 0
        foreach ($l in $lines) {
            if ($l -match '(?i)^Content-Length:\s*(\d+)') { $clen = [int]$Matches[1] }
        }
        $guard = 0
        while (($enc.GetByteCount($body) -lt $clen) -and $guard -lt 100) {
            $guard++
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $all = $enc.GetString($ms.ToArray())
            $body = $all.Substring($idx + 4)
        }

        $path = $target
        $query = ''
        $qi = $target.IndexOf('?')
        if ($qi -ge 0) { $path = $target.Substring(0, $qi); $query = $target.Substring($qi + 1) }

        $q = @{}
        if ($query) {
            foreach ($kv in $query.Split('&')) {
                if ($kv -match '^([^=]*)=(.*)$') {
                    try { $q[[Uri]::UnescapeDataString($Matches[1])] = [Uri]::UnescapeDataString($Matches[2]) } catch { }
                }
            }
        }
        $f = @{}
        if ($body) {
            foreach ($kv in $body.Split('&')) {
                if ($kv -match '^([^=]*)=(.*)$') {
                    try { $f[[Uri]::UnescapeDataString($Matches[1])] = [Uri]::UnescapeDataString($Matches[2].Replace('+', ' ')) } catch { }
                }
            }
        }

        Write-MockLog ("$method $target" + $(if ($body) { "  body=$body" } else { '' }))

        if ($path -eq '/generate_204') {
            if ($script:authed) {
                Send-Response -Stream $stream -Status '204 No Content'
                Write-MockLog '  -> 204 authed'
            } else {
                Send-Response -Stream $stream -Status '302 Found' -Extra "Location: http://127.0.0.1:$Port/portal?wlanuserip=10.5.23.47&wlanacname=TESTAC&nasip=10.5.255.254`r`n"
                Write-MockLog '  -> 302 to portal'
            }
        }
        elseif ($path -eq '/reset') {
            $script:authed = $false
            Send-Response -Stream $stream -Status '200 OK' -Body 'reset'
            Write-MockLog '  -> reset to not-authed'
        }
        elseif ($path -eq '/portal') {
            $u = ''; $p = ''
            if ($q.ContainsKey('username')) { $u = $q['username'] }
            if ($q.ContainsKey('password')) { $p = $q['password'] }
            if ($u -or $p) {
                if ($u -eq $User -and $p -eq $Pass) {
                    $script:authed = $true
                    Send-Response -Stream $stream -Status '200 OK' -Body '登录成功 LOGIN-OK'
                    Write-MockLog ("  -> LOGIN-OK  (Query mode, user=$u)")
                } else {
                    Send-Response -Stream $stream -Status '200 OK' -Body (Get-LoginPage -Err '用户名或密码错误')
                    Write-MockLog ("  -> LOGIN-FAIL (Query mode, user=$u pwd=$p)")
                }
            } else {
                Send-Response -Stream $stream -Status '200 OK' -Body (Get-LoginPage)
                Write-MockLog '  -> login page served'
            }
        }
        elseif ($path -eq '/login') {
            $u = ''; $p = ''
            if ($f.ContainsKey('username')) { $u = $f['username'] }
            if ($f.ContainsKey('password')) { $p = $f['password'] }
            if ($u -eq $User -and $p -eq $Pass) {
                $script:authed = $true
                Send-Response -Stream $stream -Status '200 OK' -Body '登录成功 LOGIN-OK'
                Write-MockLog ("  -> LOGIN-OK  (Form mode, user=$u)")
            } else {
                Send-Response -Stream $stream -Status '200 OK' -Body (Get-LoginPage -Err '用户名或密码错误')
                Write-MockLog ("  -> LOGIN-FAIL (Form mode, user=$u pwd=$p)")
            }
        }
        elseif ($path -eq '/drcom') {
            Send-Response -Stream $stream -Status '200 OK' -Body (Get-DrComPage)
            Write-MockLog '  -> Dr.COM style login page served'
        }
        elseif ($path -eq '/eportal/') {
            $u = ''; $p = ''; $y = ''; $d = ''
            if ($f.ContainsKey('DDDDD'))  { $u = $f['DDDDD'] }
            if ($f.ContainsKey('upass'))  { $p = $f['upass'] }
            if ($f.ContainsKey('yys'))    { $y = $f['yys'] }
            if ($f.ContainsKey('domain')) { $d = $f['domain'] }
            $want = $User + $Suffix
            $wl = ''; $urlp = ''
            if ($f.ContainsKey('wlanuserip')) { $wl = $f['wlanuserip'] }
            if ($f.ContainsKey('url'))        { $urlp = $f['url'] }
            Write-MockLog ("  Dr.COM login attempt: DDDDD=$u upass=$p yys=$y domain=$d wlanuserip=$wl url=$urlp")
            if ($u -eq $want -and $p -eq $Pass -and $y -eq '2') {
                $script:authed = $true
                Send-Response -Stream $stream -Status '200 OK' -Body 'Dr.COMWebLoginID_3.htm'
                Write-MockLog ("  -> DRCOM-OK  (account=$u carrier=$y domain=$d)")
            } else {
                $why = @()
                if ($u -ne $want) { $why += "account '$u' != '$want'" }
                if ($p -ne $Pass) { $why += 'bad password' }
                if ($y -ne '2')   { $why += "carrier '$y' != '2' (wrong radio option submitted)" }
                Send-Response -Stream $stream -Status '200 OK' -Body (Get-DrComPage -Err '认证失败')
                Write-MockLog ("  -> DRCOM-FAIL (" + ($why -join '; ') + ')')
            }
        }
        elseif ($path -eq '/eportal/portal/login') {
            # Newer Dr.COM (v4 / EPortal) style JSONP endpoint: everything travels in the
            # QUERY STRING, and the account carries the carrier suffix.
            $ua = ''; $up = ''; $wl = ''
            if ($q.ContainsKey('user_account'))  { $ua = $q['user_account'] }
            if ($q.ContainsKey('user_password')) { $up = $q['user_password'] }
            if ($q.ContainsKey('wlan_user_ip'))  { $wl = $q['wlan_user_ip'] }
            $want = $User + $Suffix
            Write-MockLog ("  JSONP login attempt: user_account=$ua user_password=$up wlan_user_ip=$wl")
            if ($ua -eq $want -and $up -eq $Pass) {
                $script:authed = $true
                Send-Response -Stream $stream -Status '200 OK' -Body 'dr1003({"result":1,"msg":"login success"})'
                Write-MockLog ("  -> JSONP-OK  (account=$ua ip=$wl)")
            } else {
                $why = @()
                if ($ua -ne $want) { $why += "account '$ua' != '$want'" }
                if ($up -ne $Pass) { $why += 'bad password' }
                Send-Response -Stream $stream -Status '200 OK' -Body 'dr1003({"result":0,"msg":"fail"})'
                Write-MockLog ("  -> JSONP-FAIL (" + ($why -join '; ') + ')')
            }
        }
        else {
            Send-Response -Stream $stream -Status '404 Not Found' -Body 'not found'
            Write-MockLog '  -> 404'
        }
    } catch {
        Write-MockLog ('Connection error / 连接处理异常: ' + $_.Exception.Message)
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

try { $listener.Stop() } catch { }
Write-MockLog 'mock portal stopped'
