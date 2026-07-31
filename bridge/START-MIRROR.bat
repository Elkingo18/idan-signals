@echo off
REM ==========================================================
REM  Idan Trader - Account Mirror   (READ ONLY)
REM  Double-click this AFTER TWS or IB Gateway is running
REM  and logged into the PAPER account.
REM  This never sends an order. It only reads the account.
REM ==========================================================
title Idan Trader - Account Mirror
cd /d "%~dp0"

echo.
echo   Checking ib_async...
python -m pip install --quiet --upgrade ib_async || goto :nopython

echo.
echo   ============================================
echo    1 = TWS       (port 7497)
echo    2 = Gateway   (port 4002)
echo   ============================================
set /p WHICH="   Choose 1 or 2: "

if "%WHICH%"=="2" (set PORT=4002) else (set PORT=7497)

echo.
echo   Connecting on port %PORT%  -  READ ONLY.
echo   A snapshot is taken every 60 seconds. Press Ctrl+C to stop.
echo.
python account_mirror.py --port %PORT% --loop 60
goto :end

:nopython
echo.
echo   Python was not found on this machine.
echo   Install it from python.org and tick "Add python.exe to PATH".

:end
echo.
pause
