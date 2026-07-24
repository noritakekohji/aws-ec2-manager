@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo ================================================
echo  File Transfer Check (SMB round-trip)
echo ================================================
echo.

:: ===== 運用者が編集する既定値（ここに引数を設定） =====
set "SHARE_LIST=%~dp0shares.lst"
set "SIZE_MB=10"
set "TIMEOUT_SEC=60"
set "HTML_REPORT="
set "FAIL_ONLY="
:: ======================================================

if not exist "!SHARE_LIST!" (
    echo [ERROR] Share list not found: !SHARE_LIST!
    echo Usage: %~nx0 [extra PowerShell args...]
    pause
    exit /b 2
)

set "PSARGS=-ShareList "!SHARE_LIST!" -SizeMB !SIZE_MB! -TimeoutSec !TIMEOUT_SEC!"
if not "!HTML_REPORT!"=="" set "PSARGS=!PSARGS! -HtmlReport "!HTML_REPORT!""
if /I "!FAIL_ONLY!"=="on"  set "PSARGS=!PSARGS! -FailOnly"

for /f %%t in ('powershell -NoLogo -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TIMESTAMP=%%t"
set "OPS_LOG_FILE=%~dpn0_!TIMESTAMP!.log"

echo Share list : !SHARE_LIST!
echo Test size  : !SIZE_MB! MB
echo.
echo Running...
echo.

:: bat の既定値 + コマンドライン引数(%*)で上書き可能
powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Check-FileTransfer.ps1" !PSARGS! %*

echo.
pause
endlocal
