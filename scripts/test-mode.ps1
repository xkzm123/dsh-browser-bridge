# test-mode.ps1 - regression test for the targetMode plumbing (managed instance).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-mode.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-mode.ps1 -KeepOpen
#
# What it proves:
#   * browsers reports a managed flag and --managed-only filters on it
#   * launch starts (or reuses) an isolated instance and returns its window
#   * the managed window is drivable (title reads back)
#   * close-managed stops ONLY the managed instance
#   * the windows the user already had open are still there afterwards
#
# It never touches a user window, and it always closes the instance it started
# unless -KeepOpen is passed. ASCII only on purpose: this file must survive any
# console code page.

param(
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bctl = Join-Path $here 'bctl.ps1'

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

function Rows($argv) {
    $r = Run $argv
    try {
        $parsed = $r.text | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    }
    catch { return @() }
}

Write-Host '== 0. baseline' -ForegroundColor Cyan
$before = @(Rows @('browsers', '--json'))
$userBefore = @($before | Where-Object { -not $_.managed })
$userPidsBefore = (($userBefore | ForEach-Object { [int]$_.pid }) | Sort-Object) -join ','
Write-Host ("  windows before: " + $before.Count + " (user: " + $userBefore.Count + ")")

Write-Host '== 1. browsers carries a managed flag' -ForegroundColor Cyan
$hasFlag = ($before.Count -eq 0) -or (@($before | Where-Object { $null -ne $_.managed }).Count -eq $before.Count)
Check 'every row has managed' $hasFlag 'at least one row came back without the field'

Write-Host '== 2. launch' -ForegroundColor Cyan
$launch = Run @('launch', '--json')
$info = $null
try { $info = $launch.text | ConvertFrom-Json } catch { }
Check 'launch ok' ($info -and $info.ok -eq $true) $launch.text
$managedPid = if ($info) { [int]$info.pid } else { 0 }
$managedHandle = if ($info) { [int64]$info.handle } else { 0 }
Check 'launch returned a window handle' ($managedHandle -ne 0) 'handle is 0'

Write-Host '== 3. managed-only filters on it' -ForegroundColor Cyan
$managed = @(Rows @('browsers', '--managed-only', '--json'))
$managedPids = (($managed | ForEach-Object { [int]$_.pid }) | Sort-Object) -join ','
Check 'managed-only returns exactly the launched window' `
    (($managed.Count -eq 1) -and ([int]$managed[0].pid -eq $managedPid)) `
    ("got [" + $managedPids + "] expected [" + $managedPid + "]")
Check 'managed rows are flagged managed' (($managed.Count -gt 0) -and ($managed[0].managed -eq $true)) 'managed flag false'

Write-Host '== 4. managed list agrees' -ForegroundColor Cyan
$list = @(Rows @('managed', '--json'))
Check 'managed lists the same pid' (($list.Count -eq 1) -and ([int]$list[0].pid -eq $managedPid)) ("got " + $list.Count)

Write-Host '== 5. the managed window is drivable' -ForegroundColor Cyan
$spec = [string]$managedPid + ':' + [string]$managedHandle
$title = Run @('title', $spec, '--json')
Check 'title reads back' ($title.code -eq 0 -and $title.text -match '"ok":true') $title.text

Write-Host '== 6. user windows are untouched' -ForegroundColor Cyan
$after = @(Rows @('browsers', '--json'))
$userAfter = @($after | Where-Object { -not $_.managed })
$userPidsAfter = (($userAfter | ForEach-Object { [int]$_.pid }) | Sort-Object) -join ','
Check 'user window set unchanged' ($userPidsBefore -eq $userPidsAfter) ("before [" + $userPidsBefore + "] after [" + $userPidsAfter + "]")

if ($KeepOpen) {
    Write-Host '== 7. close-managed skipped (-KeepOpen)' -ForegroundColor Yellow
}
else {
    Write-Host '== 7. close-managed' -ForegroundColor Cyan
    $close = Run @('close-managed', '--json')
    Check 'close-managed ok' ($close.text -match '"ok":true') $close.text
    Start-Sleep -Milliseconds 600
    $left = @(Rows @('browsers', '--managed-only', '--json'))
    Check 'no managed window left' ($left.Count -eq 0) ("still " + $left.Count)
    $finalUser = @((Rows @('browsers', '--json')) | Where-Object { -not $_.managed })
    $finalPids = (($finalUser | ForEach-Object { [int]$_.pid }) | Sort-Object) -join ','
    Check 'user windows survived' ($finalPids -eq $userPidsBefore) ("before [" + $userPidsBefore + "] after [" + $finalPids + "]")
}

Write-Host ''
Write-Host ("PASS " + $pass + "  FAIL " + $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
exit 0
