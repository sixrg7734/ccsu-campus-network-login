<#
  Run-Tests.ps1 -- end-to-end tests for Connect-CampusNet.ps1
  ================================================================
  Starts a fake portal (Mock-Portal.ps1) and drives the real script
  against it, then checks what the PORTAL side actually received.
  "The script did not throw" is not evidence -- the portal log is.

  起一个假 Portal，然后真的运行主脚本，从【门户端】核对收到的请求。
  「脚本没报错」不算证据，门户端的日志才算。

  Fully hermetic: every URL points at 127.0.0.1, no internet access needed.
  完全本地：所有 URL 都指向 127.0.0.1，不需要联网（可在 CI 里跑）。

  Usage / 用法:  .\tests\Run-Tests.ps1     (exit 0 = all passed)
  Artifacts:     tests\test-report.txt, tests\mock.log
#>
#Requires -Version 5.1
[CmdletBinding()]
param([int]$Port = 18080)

$ErrorActionPreference = 'Continue'
$here    = $PSScriptRoot
$root    = Split-Path -Parent $here
$main    = Join-Path $root 'Connect-CampusNet.ps1'
$mock    = Join-Path $here 'Mock-Portal.ps1'
$mockLog = Join-Path $here 'mock.log'
$report  = Join-Path $here 'test-report.txt'
$user    = 'testuser'
$pass    = 'testpass123'

$results = New-Object System.Collections.ArrayList

# Drive the scripts with the SAME PowerShell host that is running this test,
# so a `pwsh` (PowerShell 7) run really tests PowerShell 7.
# 用「当前这个测试所在的 PowerShell 宿主」去跑被测脚本，
# 这样在 pwsh 下运行才真的验证了 PowerShell 7。
$script:HostExe = 'powershell.exe'
if ($PSVersionTable.PSEdition -eq 'Core') {
    $cand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cand) { $script:HostExe = $cand.Source } else { $script:HostExe = 'pwsh' }
}

function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    [void]$results.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
    if ($Pass) { Write-Host ("  [PASS] " + $Name) -ForegroundColor Green }
    else       { Write-Host ("  [FAIL] " + $Name + "  -- " + $Detail) -ForegroundColor Red }
}

function New-TestConfig {
    param([string]$File, [string]$LoginUrl, [string]$PortalUrl = '', [int]$Retry = 2)
    $o = [ordered]@{
        'LoginUrl'        = $LoginUrl
        'PortalUrl'       = $PortalUrl
        'Mode'            = 'Auto'
        'UserField'       = 'username'
        'PwdField'        = 'password'
        'PwdTransform'    = 'plain'
        'PwdTemplate'     = '{pwd}'
        'TokenRegex'      = ''
        'ExtraFields'     = $null
        'User'            = $user
        'UserSuffix'      = ''
        'PwdEnc'          = ''
        'PwdPlain'        = $pass
        'WifiProfile'     = ''
        'SuccessTestUrl'  = "http://127.0.0.1:$Port/generate_204"
        'SuccessStatus'   = 204
        'SuccessRegex'    = ''
        'AllowInvalidCert' = $false
        'RetryCount'      = $Retry
        'RetryDelaySec'   = 1
        'Headers'         = $null
    }
    Set-Content -LiteralPath $File -Value ($o | ConvertTo-Json -Depth 6) -Encoding UTF8
    return $File
}

function Invoke-Main {
    param([string]$Config, [string[]]$ExtraArgs = @())
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $main, '-ConfigPath', $Config, '-NoLog') + $ExtraArgs
    $out = (& $script:HostExe @a 2>&1 | Out-String)
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

function Reset-Portal {
    try { $null = Invoke-WebRequest ("http://127.0.0.1:{0}/reset" -f $Port) -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop } catch { }
}

Write-Host ''
Write-Host '==== Campus network script: end-to-end tests ====' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $main)) { Write-Host ('Missing ' + $main) -ForegroundColor Red; exit 2 }
if (Test-Path -LiteralPath $mockLog) { Remove-Item -LiteralPath $mockLog -Force -ErrorAction SilentlyContinue }

# ---------- start the mock portal ----------
$mockArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $mock + '" -Port ' + $Port + ' -MaxSeconds 300 -LogFile "' + $mockLog + '"'
$mockProc = Start-Process -FilePath $script:HostExe -ArgumentList $mockArgs -WindowStyle Hidden -PassThru
Write-Host ('host=' + $script:HostExe + '  mock portal pid=' + $mockProc.Id + ' port=' + $Port)

$ready = $false
for ($i = 0; $i -lt 50; $i++) {
    try {
        $null = Invoke-WebRequest ("http://127.0.0.1:{0}/reset" -f $Port) -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        $ready = $true; break
    } catch { Start-Sleep -Milliseconds 300 }
}
if (-not $ready) {
    Write-Host 'mock portal did not start; aborting.' -ForegroundColor Red
    try { Stop-Process -Id $mockProc.Id -Force } catch { }
    exit 3
}
Write-Host 'mock portal ready.' -ForegroundColor Green
Write-Host ''

function Get-NewMockLog {
    param([int]$From)
    if (-not (Test-Path -LiteralPath $mockLog)) { return '' }
    $t = Get-Content -LiteralPath $mockLog -Raw -Encoding UTF8
    if (-not $t) { return '' }
    if ($From -ge $t.Length) { return '' }
    return $t.Substring($From)
}

$logPos = 0
if (Test-Path -LiteralPath $mockLog) { $logPos = (Get-Content -LiteralPath $mockLog -Raw -Encoding UTF8).Length }

# ---------- A: Form mode ----------
Write-Host 'A  Form mode (POST) + correct password' -ForegroundColor White
$cfgA = New-TestConfig -File (Join-Path $here 'cfg-A-form.json') -LoginUrl ("http://127.0.0.1:{0}/portal" -f $Port)
Reset-Portal
$rA = Invoke-Main -Config $cfgA -ExtraArgs @('-Force','-Quiet')
$deltaA = Get-NewMockLog -From $logPos; $logPos += $deltaA.Length
Add-Result 'A: exit code 0'                 ($rA.Code -eq 0)             ("exit=" + $rA.Code)
Add-Result 'A: portal received POST /login' ($deltaA -match 'POST /login') 'no POST /login in mock.log'
Add-Result 'A: portal says login OK'        ($deltaA -match 'LOGIN-OK\s+\(Form') 'no Form-mode LOGIN-OK in mock.log'
Add-Result 'A: hidden fields carried over'  ($deltaA -match 'wlanuserip=10\.5\.23\.47' -and $deltaA -match 'wlanacname=TESTAC') 'hidden fields from the page were not submitted'

# ---------- B: Query mode ----------
Write-Host ''
Write-Host 'B  Query mode (params in the URL) + correct password' -ForegroundColor White
$cfgB = New-TestConfig -File (Join-Path $here 'cfg-B-query.json') -LoginUrl ("http://127.0.0.1:{0}/portal?wlanuserip=10.5.23.47&wlanacname=TESTAC" -f $Port)
Reset-Portal
$rB = Invoke-Main -Config $cfgB -ExtraArgs @('-Force','-Quiet')
$deltaB = Get-NewMockLog -From $logPos; $logPos += $deltaB.Length
Add-Result 'B: exit code 0'                  ($rB.Code -eq 0) ('exit=' + $rB.Code)
Add-Result 'B: portal got GET with account'  ($deltaB -match 'GET /portal\?.+username=') 'no username in the GET query'
Add-Result 'B: original params preserved'    ($deltaB -match 'wlanacname=TESTAC') 'the pre-existing query params were dropped'
Add-Result 'B: portal says login OK'         ($deltaB -match 'LOGIN-OK\s+\(Query') 'no Query-mode LOGIN-OK in mock.log'

# ---------- C: wrong password ----------
Write-Host ''
Write-Host 'C  Wrong password -> must fail' -ForegroundColor White
$cfgC = New-TestConfig -File (Join-Path $here 'cfg-C-bad.json') -LoginUrl ("http://127.0.0.1:{0}/portal" -f $Port)
$cObj = Get-Content -LiteralPath $cfgC -Raw -Encoding UTF8 | ConvertFrom-Json
$cObj.PwdPlain = 'wrong-password'
Set-Content -LiteralPath $cfgC -Value ($cObj | ConvertTo-Json -Depth 6) -Encoding UTF8
Reset-Portal
$rC = Invoke-Main -Config $cfgC -ExtraArgs @('-Force','-Quiet')
$deltaC = Get-NewMockLog -From $logPos; $logPos += $deltaC.Length
Add-Result 'C: exit code 1 (honest failure)' ($rC.Code -eq 1) ("exit=" + $rC.Code + " (expected 1)")
Add-Result 'C: portal logged LOGIN-FAIL'     ($deltaC -match 'LOGIN-FAIL') 'no LOGIN-FAIL in mock.log'

# ---------- D: DPAPI ciphertext ----------
Write-Host ''
Write-Host 'D  DPAPI-encrypted password (PwdEnc) round-trip' -ForegroundColor White
$cfgD = New-TestConfig -File (Join-Path $here 'cfg-D-dpapi.json') -LoginUrl ("http://127.0.0.1:{0}/portal" -f $Port)
$dObj = Get-Content -LiteralPath $cfgD -Raw -Encoding UTF8 | ConvertFrom-Json
$dObj.PwdPlain = ''
$dObj.PwdEnc   = ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $pass -AsPlainText -Force)
Set-Content -LiteralPath $cfgD -Value ($dObj | ConvertTo-Json -Depth 6) -Encoding UTF8
Reset-Portal
$rD = Invoke-Main -Config $cfgD -ExtraArgs @('-Force','-Quiet')
$deltaD = Get-NewMockLog -From $logPos; $logPos += $deltaD.Length
Add-Result 'D: exit code 0 (decrypt worked)' ($rD.Code -eq 0) ("exit=" + $rD.Code)
Add-Result 'D: decrypted password is correct' ($deltaD -match 'LOGIN-OK') 'no LOGIN-OK -- decrypted password does not match'

# ---------- E: -ProbeJson contract (what Setup consumes) ----------
Write-Host ''
Write-Host 'E  -ProbeJson output contract (used by Setup-CampusNet.ps1)' -ForegroundColor White
$cfgE = New-TestConfig -File (Join-Path $here 'cfg-E-probe.json') -LoginUrl '' -PortalUrl ("http://127.0.0.1:{0}/portal" -f $Port)
Reset-Portal
$rE = Invoke-Main -Config $cfgE -ExtraArgs @('-ProbeJson')
$pj = $null
try { $pj = ($rE.Out.Trim() | ConvertFrom-Json) } catch { $pj = $null }
Add-Result 'E: stdout is valid JSON'   ($null -ne $pj) 'could not parse -ProbeJson stdout as JSON'
if ($pj) {
    Add-Result 'E: Online = false'      ($pj.Online -eq $false)          ('Online=' + $pj.Online)
    Add-Result 'E: PortalUrl detected'  ($pj.PortalUrl -match '/portal') ('PortalUrl=' + $pj.PortalUrl)
    Add-Result 'E: guessed user field'  ($pj.GuessUserField -eq 'username') ('GuessUserField=' + $pj.GuessUserField)
    Add-Result 'E: guessed pwd field'   ($pj.GuessPwdField -eq 'password')  ('GuessPwdField=' + $pj.GuessPwdField)
    Add-Result 'E: form action resolved' ($pj.FormAction -match '/login')   ('FormAction=' + $pj.FormAction)
    Add-Result 'E: fields enumerated'   ($pj.Fields.Count -ge 5)            ('Fields=' + $pj.Fields.Count)
} else {
    Add-Result 'E: Online = false' $false 'JSON unavailable'
    Add-Result 'E: PortalUrl detected' $false 'JSON unavailable'
    Add-Result 'E: guessed user field' $false 'JSON unavailable'
    Add-Result 'E: guessed pwd field' $false 'JSON unavailable'
    Add-Result 'E: form action resolved' $false 'JSON unavailable'
    Add-Result 'E: fields enumerated' $false 'JSON unavailable'
}

# ---------- F: Dr.COM style (account suffix + carrier radio) ----------
Write-Host ''
Write-Host 'F  Dr.COM style: account suffix + carrier radio (the CCSU portal shape)' -ForegroundColor White
$cfgF = New-TestConfig -File (Join-Path $here 'cfg-F-drcom.json') -LoginUrl ("http://127.0.0.1:{0}/drcom" -f $Port)
$fObj = Get-Content -LiteralPath $cfgF -Raw -Encoding UTF8 | ConvertFrom-Json
$fObj.UserField  = 'DDDDD'
$fObj.PwdField   = 'upass'
$fObj.UserSuffix = '@lt'
$fObj.ExtraFields = @{ 'url' = 'drappall'; 'wlanuserip' = '{localip}' }
Set-Content -LiteralPath $cfgF -Value ($fObj | ConvertTo-Json -Depth 6) -Encoding UTF8
Reset-Portal
$rF = Invoke-Main -Config $cfgF -ExtraArgs @('-Force','-Quiet')
$deltaF = Get-NewMockLog -From $logPos; $logPos += $deltaF.Length
Add-Result 'F: exit code 0'                        ($rF.Code -eq 0) ("exit=" + $rF.Code)
Add-Result 'F: account sent with the @lt suffix'   ($deltaF -match 'DDDDD=testuser@lt') 'the @lt suffix was not appended to the account'
Add-Result 'F: password sent as upass'             ($deltaF -match 'upass=testpass123') 'the upass field was not submitted'
Add-Result 'F: carrier radio = the CHECKED option' ($deltaF -match 'yys=2') 'checked radio (2) not sent -- parser probably kept the first or last option'
Add-Result 'F: {localip} expanded to a real IP'    ($deltaF -match 'wlanuserip=\d+\.\d+\.\d+\.\d+') 'the {localip} placeholder was not expanded'
Add-Result 'F: static ExtraFields passed through'  ($deltaF -match 'url=drappall') 'ExtraFields values were not submitted'
Add-Result 'F: portal accepted the login'          ($deltaF -match 'DRCOM-OK') 'the mock Dr.COM portal rejected the login'

# ---------- G: -ProbeJson on the Dr.COM page ----------
Write-Host ''
Write-Host 'G  -ProbeJson on the Dr.COM page (field + option detection)' -ForegroundColor White
$cfgG = New-TestConfig -File (Join-Path $here 'cfg-G-drcom-probe.json') -LoginUrl '' -PortalUrl ("http://127.0.0.1:{0}/drcom" -f $Port)
Reset-Portal
$rG = Invoke-Main -Config $cfgG -ExtraArgs @('-ProbeJson')
$pjG = $null
try { $pjG = ($rG.Out.Trim() | ConvertFrom-Json) } catch { $pjG = $null }
if (-not $pjG) {
    Add-Result 'G: -ProbeJson returned valid JSON' $false 'could not parse stdout as JSON'
} else {
    Add-Result 'G: -ProbeJson returned valid JSON' $true ''
    Add-Result 'G: guessed account field = DDDDD'  ($pjG.GuessUserField -eq 'DDDDD') ('GuessUserField=' + $pjG.GuessUserField)
    Add-Result 'G: guessed password field = upass' ($pjG.GuessPwdField -eq 'upass') ('GuessPwdField=' + $pjG.GuessPwdField)
    Add-Result 'G: guessed carrier field = yys'    ($pjG.GuessCarrierField -eq 'yys') ('GuessCarrierField=' + $pjG.GuessCarrierField)
    $yys = $pjG.Fields | Where-Object { $_.Name -eq 'yys' }
    $dom = $pjG.Fields | Where-Object { $_.Name -eq 'domain' }
    Add-Result 'G: radio group enumerated (3 options)' ($yys -and $yys.Type -eq 'radio' -and $yys.Options.Count -eq 3) 'the yys radio group was not enumerated'
    Add-Result 'G: radio binds to the CHECKED option'  ($yys -and $yys.Value -eq '2') ('yys value=' + $(if ($yys) { $yys.Value } else { '<missing>' }) + ' (expected 2, the checked one)')
    Add-Result 'G: <select> parsed with its options'   ($dom -and $dom.Type -eq 'select' -and $dom.Options.Count -eq 3) 'the <select> was not parsed'
    Add-Result 'G: <select> binds to the SELECTED option' ($dom -and $dom.Value -eq '1') ('domain value=' + $(if ($dom) { $dom.Value } else { '<missing>' }) + ' (expected 1, the selected one)')
}

# ---------- H: Mode=Url (replay a captured request) ----------
Write-Host ''
Write-Host 'H  Mode=Url: replay a captured login request (the JS-rendered portal escape hatch)' -ForegroundColor White
$cfgH = New-TestConfig -File (Join-Path $here 'cfg-H-url.json') -LoginUrl ("http://127.0.0.1:{0}/eportal/portal/login?user_account={{user}}&user_password={{pwd}}&wlan_user_ip={{localip}}&jsVersion=4.1" -f $Port)
$hObj = Get-Content -LiteralPath $cfgH -Raw -Encoding UTF8 | ConvertFrom-Json
$hObj.Mode       = 'Url'
$hObj.UserSuffix = '@lt'
Set-Content -LiteralPath $cfgH -Value ($hObj | ConvertTo-Json -Depth 6) -Encoding UTF8
Reset-Portal
$rH = Invoke-Main -Config $cfgH -ExtraArgs @('-Force','-Quiet')
$deltaH = Get-NewMockLog -From $logPos; $logPos += $deltaH.Length
Add-Result 'H: exit code 0'                          ($rH.Code -eq 0) ("exit=" + $rH.Code)
Add-Result 'H: {user} filled (with suffix), URL-encoded' ($deltaH -match 'user_account=testuser@lt') 'the {user} placeholder was not substituted correctly'
Add-Result 'H: {pwd} filled from the config'         ($deltaH -match 'user_password=testpass123') 'the {pwd} placeholder was not substituted'
Add-Result 'H: {localip} filled with a real IP'      ($deltaH -match 'wlan_user_ip=\d+\.\d+\.\d+\.\d+') 'the {localip} placeholder was not substituted'
Add-Result 'H: literal params kept verbatim'         ($deltaH -match 'jsVersion=4\.1') 'literal query parameters were lost'
Add-Result 'H: portal accepted the replay'           ($deltaH -match 'JSONP-OK') 'the mock rejected the replayed request'

# ---------- teardown ----------
try { Stop-Process -Id $mockProc.Id -Force -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Milliseconds 400

$total  = $results.Count
$passed = ($results | Where-Object { $_.Pass }).Count
$allOk  = ($passed -eq $total)

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('Campus network script -- end-to-end test report / 端到端测试报告')
[void]$sb.AppendLine('Time / 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
[void]$sb.AppendLine('Script / 主脚本: ' + $main)
[void]$sb.AppendLine('Host: ' + $PSVersionTable.PSVersion.ToString() + ' on ' + [Environment]::OSVersion.VersionString)
[void]$sb.AppendLine('')
foreach ($r in $results) {
    [void]$sb.AppendLine(('[{0}] {1}' -f $(if ($r.Pass) { 'PASS' } else { 'FAIL' }), $r.Name))
    if (-not $r.Pass) { [void]$sb.AppendLine('        详情: ' + $r.Detail) }
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine(('Result / 结果: {0}/{1} passed' -f $passed, $total))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- A (Form) ---');  [void]$sb.AppendLine($rA.Out)
[void]$sb.AppendLine('--- B (Query) ---'); [void]$sb.AppendLine($rB.Out)
[void]$sb.AppendLine('--- C (wrong pwd) ---'); [void]$sb.AppendLine($rC.Out)
[void]$sb.AppendLine('--- D (DPAPI) ---'); [void]$sb.AppendLine($rD.Out)
[void]$sb.AppendLine('--- E (-ProbeJson) ---'); [void]$sb.AppendLine($rE.Out)
[void]$sb.AppendLine('--- F (Dr.COM + suffix) ---'); [void]$sb.AppendLine($rF.Out)
[void]$sb.AppendLine('--- G (Dr.COM -ProbeJson) ---'); [void]$sb.AppendLine($rG.Out)
[void]$sb.AppendLine('--- H (Mode=Url replay) ---'); [void]$sb.AppendLine($rH.Out)
Set-Content -LiteralPath $report -Value $sb.ToString() -Encoding UTF8

Write-Host ''
if ($allOk) { Write-Host ('==== ALL PASSED {0}/{1} ====' -f $passed, $total) -ForegroundColor Green }
else        { Write-Host ('==== FAILURES {0}/{1} ====' -f $passed, $total) -ForegroundColor Red }
Write-Host ('report: ' + $report)

if ($allOk) { exit 0 } else { exit 1 }
