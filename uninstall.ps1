# uninstall.ps1 - remove dsh-browser-bridge from the DSH skill catalog
param(
    [string]$SkillsDir = (Join-Path $env:USERPROFILE '.dsh\skills')
)

$ErrorActionPreference = 'Continue'
$dst = Join-Path $SkillsDir 'dsh-browser-bridge'

# 停掉本地桥服务
$conn = Get-NetTCPConnection -LocalPort 8737 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn) {
    Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
    Write-Host "stopped bridge server (pid $($conn.OwningProcess))"
}

if (Test-Path $dst) {
    Remove-Item $dst -Recurse -Force
    Write-Host "removed $dst" -ForegroundColor Green
}
else {
    Write-Host "not installed at $dst"
}

Write-Host ''
Write-Host 'manual step: open Tampermonkey -> Dashboard -> delete "dsh-browser-bridge"' -ForegroundColor Yellow
