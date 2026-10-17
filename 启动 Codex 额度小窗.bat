@echo off
start "Codex 额度小窗" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0CodexQuotaWidget.ps1"

