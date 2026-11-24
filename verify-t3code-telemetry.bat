@echo off
chcp 65001 >nul
setlocal

echo T3 Code テレメトリ検証スクリプトを実行します...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-t3code-telemetry.ps1" %*
echo.
echo --------------------------------------------------------------------
echo リアルタイム監視を行う場合は、以下のように実行してください:
echo   verify-t3code-telemetry.bat -WatchSeconds 30
echo --------------------------------------------------------------------
pause
