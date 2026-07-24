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

if "%~1"=="" (
    rem --- 引数なし（ダブルクリック等）: 上の SET ブロックの既定値を使う ---
    if not exist "!SHARE_LIST!" (
        echo [ERROR] Share list not found: !SHARE_LIST!
        echo Usage: %~nx0 [PowerShell args...]
        pause
        exit /b 2
    )
    set "PSARGS=-ShareList "!SHARE_LIST!" -SizeMB !SIZE_MB! -TimeoutSec !TIMEOUT_SEC!"
    if not "!HTML_REPORT!"=="" set "PSARGS=!PSARGS! -HtmlReport "!HTML_REPORT!""
    if /I "!FAIL_ONLY!"=="on"  set "PSARGS=!PSARGS! -FailOnly"
) else (
    rem --- 引数あり: コマンドライン引数を優先。-ShareList 未指定なら既定を補う ---
    set "EXTRA=%*"
    set "STRIPPED=!EXTRA:-ShareList=!"
    if "!STRIPPED!"=="!EXTRA!" (
        set "PSARGS=-ShareList "!SHARE_LIST!" !EXTRA!"
    ) else (
        set "PSARGS=!EXTRA!"
    )
)

for /f %%t in ('powershell -NoLogo -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TIMESTAMP=%%t"
set "OPS_LOG_FILE=%~dpn0_!TIMESTAMP!.log"

echo Running...
echo.

powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Check-FileTransfer.ps1" !PSARGS!

echo.
pause
endlocal
