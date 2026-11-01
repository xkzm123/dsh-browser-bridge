@echo off
rem bctl.cmd - convenience wrapper so the CLI can be run from cmd.exe / ssh with UTF-8
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bctl.ps1" %*
