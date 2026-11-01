# install.ps1 - install dsh-browser-bridge as a DSH skill
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -SkillsDir "D:\my\skills"
#
param(
    [string]$SkillsDir = (Join-Path $env:USERPROFILE '.dsh\skills'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$name = 'dsh-browser-bridge'
$dst = Join-Path $SkillsDir $name

Write-Host "source : $src"
Write-Host "target : $dst"

if ((Test-Path $dst) -and -not $Force) {
    Write-Host ''
    Write-Host "already installed. re-run with -Force to overwrite." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }

# 复制时排除 .git 和临时产物
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Path $dst -Force | Out-Null

$exclude = @('.git', 'node_modules', '.gitignore')
Get-ChildItem -Path $src -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
    Copy-Item $_.FullName -Destination $dst -Recurse -Force
}

Write-Host ''
Write-Host "installed -> $dst" -ForegroundColor Green
Write-Host ''
Write-Host 'verify:' -ForegroundColor Cyan
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$dst\scripts\bctl.ps1`" doctor"
Write-Host ''
Write-Host 'next (optional, enables the JS bridge):' -ForegroundColor Cyan
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$dst\scripts\bctl.ps1`" bridge start"
Write-Host '  then open http://127.0.0.1:8737/install.user.js in the browser and click 安装'
Write-Host ''
Write-Host 'restart the DSH session (or start a new one) so the skill shows up in the catalog.' -ForegroundColor Yellow
