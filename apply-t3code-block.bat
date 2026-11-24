@echo off
chcp 65001 >nul
setlocal

:: 管理者権限チェック & 自動昇格
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 管理者権限へ昇格して T3 Code テレメトリ対策パッチを適用します...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply-t3code-block.ps1" %*
echo.
pause
