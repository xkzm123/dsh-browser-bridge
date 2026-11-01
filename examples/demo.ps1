# demo.ps1 - 一个完整的自动化范例：读取当前页、定位元素、点击、验证
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\demo.ps1 -Pid 13008
#
param(
    [Parameter(Mandatory = $true)][int]$Pid,
    [string]$Keyword = '登录'
)

$ErrorActionPreference = 'Stop'
$bctl = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\bctl.ps1'

function Run($args) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl @args }

Write-Host '== 1. 体检 ==' -ForegroundColor Cyan
$env:BCTL = 1
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl doctor

Write-Host "`n== 2. 目标确认 ==" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl title $Pid
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl url $Pid

Write-Host "`n== 3. 定位元素（关键词: $Keyword）==" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl uia $Pid --pattern $Keyword --limit 20

Write-Host "`n== 4. 操作前截图 ==" -ForegroundColor Cyan
$before = Join-Path $env:TEMP 'bctl-before.png'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl shot --win $Pid --file $before
Write-Host "   $before"

Write-Host "`n== 5. 点击（如果你只想看效果，把下面这行注释掉）==" -ForegroundColor Yellow
# & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl clickel $Pid $Keyword

Write-Host "`n== 6. 操作后截图，人工比对 ==" -ForegroundColor Cyan
$after = Join-Path $env:TEMP 'bctl-after.png'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl shot --win $Pid --file $after
Write-Host "   $after"

Write-Host "`n== 7. 如果装了 JS 桥，可以直接读 DOM 验证 ==" -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bctl js "document.title + ' | ' + __qa('a').length + ' links'" --timeout 8
