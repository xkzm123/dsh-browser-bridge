# test-guard.ps1 - 回归测试：确认插件不会关掉浏览器窗口，且导航不重复
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-guard.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-guard.ps1 -Pid 12345
#
# 前提：本机已经打开一个 Edge/Chrome 窗口。脚本不会启动浏览器。

param(
    [int]$BrowserPid = 0
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bctl = Join-Path $here 'bctl.ps1'
$page = Join-Path (Split-Path -Parent $here) 'examples\guard-test.html'
$pageUrl = 'file:///' + ($page -replace '\\', '/' -replace ' ', '%20')

$pass = 0
$fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { $script:pass++; Write-Host ("  PASS  " + $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $name + "  " + $detail) -ForegroundColor Red }
}

function Run($argv) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl @argv 2>&1
    return @{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

Write-Host '== 0. 找到浏览器' -ForegroundColor Cyan
if ($BrowserPid -eq 0) {
    $r = Run @('browsers', '--json')
    try { $rows = $r.text | ConvertFrom-Json } catch { $rows = @() }
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Host '  没有可用的浏览器窗口，先打开一个再跑这个测试。' -ForegroundColor Yellow
        exit 2
    }
    $BrowserPid = [int]($rows[0].pid)
}
Write-Host ("  pid = " + $BrowserPid)

$before = Run @('browsers', '--json')
$handleBefore = ([regex]::Match($before.text, '"handle"\s*:\s*(\d+)')).Groups[1].Value

Write-Host '== 1. 打开守卫测试页' -ForegroundColor Cyan
[void](Run @('nav', "$BrowserPid", $pageUrl, '--new-tab'))
Start-Sleep -Milliseconds 2500

# 等页面真正渲染出来再断言，否则时序抖动会让整轮测试假红
function Wait-GuardPage([int]$Ms) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $deadline) {
        $r = Run @('find', "$BrowserPid", '关闭', '--json')
        if ($r.text -match 'fake-close') { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}
Check '测试页渲染完成' (Wait-GuardPage 10000) '(10 秒内没等到页面里的测试按钮)'

Write-Host '== 2. 快照默认不含窗口按钮' -ForegroundColor Cyan
$uia = Run @('uia', "$BrowserPid", '--limit', '400')
$hasChrome = ($uia.text -match '最小化|还原|Maximize|Minimize')
Check '快照不出现窗口 chrome' (-not $hasChrome) '(出现了最小化/还原)'

Write-Host '== 3. 找「关闭」只命中页面元素' -ForegroundColor Cyan
$find = Run @('find', "$BrowserPid", '关闭', '--json')
try { $hits = $find.text | ConvertFrom-Json } catch { $hits = @() }
$allInPage = $true
foreach ($h in @($hits)) { if ([int]$h.y -lt 100) { $allInPage = $false } }
Check '「关闭」全部落在页面区域（y >= 100）' $allInPage ("有元素 y=" + (($hits | ForEach-Object { $_.y }) -join ','))

Write-Host '== 4. 点「关闭」不能关掉窗口' -ForegroundColor Cyan
$click = Run @('clickel', "$BrowserPid", '关闭', '--type', 'Button')
$after = Run @('browsers', '--json')
$handleAfter = ([regex]::Match($after.text, '"handle"\s*:\s*(\d+)')).Groups[1].Value
Check '窗口仍在' (($after.text -notmatch '"ok"\s*:\s*false') -and $handleAfter -ne '') ("click=" + $click.code)
Check 'handle 未变' ($handleBefore -eq $handleAfter) ("before=$handleBefore after=$handleAfter")

Start-Sleep -Milliseconds 900
$txt = Run @('text', "$BrowserPid", '--json')
# ConvertTo-Json 会把中文转成 \uXXXX，必须先解析再比字符串
try { $txtObj = $txt.text | ConvertFrom-Json } catch { $txtObj = $null }
$pageText = if ($txtObj) { [string]$txtObj.text } else { '' }
Check '页面按钮被点到（不是标题栏）' ($pageText -match '页面按钮被点到了') '(页面文案没变，可能点空了)'

Write-Host '== 5. 同一 URL 不重复导航' -ForegroundColor Cyan
$nav1 = Run @('nav', "$BrowserPid", $pageUrl, '--json')
Check '已打开时返回 reused=true' ($nav1.text -match '"reused"\s*:\s*true') $nav1.text.Substring(0, [Math]::Min(120, $nav1.text.Length))

Write-Host '== 6. 拒绝关闭类快捷键' -ForegroundColor Cyan
$k = Run @('key', 'CTRL+W')
Check 'CTRL+W 被拒绝' ($k.code -ne 0) ("exit=" + $k.code)

Write-Host '== 7. ensure 状态机' -ForegroundColor Cyan
$e = Run @('ensure', '--json')
Check 'state = ok' ($e.text -match '"state"\s*:\s*"ok"') $e.text.Substring(0, [Math]::Min(120, $e.text.Length))

Write-Host ''
Write-Host ("结果: PASS " + $pass + " / FAIL " + $fail) -ForegroundColor ($(if ($fail -eq 0) { 'Green' } else { 'Red' }))
if ($fail -gt 0) { exit 1 }
