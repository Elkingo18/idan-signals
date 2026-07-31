@echo off
REM ==========================================================
REM  Idan Trader Bridge - Windows launcher
REM  Double-click this AFTER IB Gateway / TWS is running and
REM  logged into the PAPER account.
REM ==========================================================
title Idan Trader Bridge
cd /d "%~dp0"

echo.
echo   Checking ib_async...
python -m pip install --quiet --upgrade ib_async || goto :nopython

echo.
echo   ============================================
echo    1 = DRY RUN   (recommended the first time)
echo    2 = LIVE      (sends real paper orders)
echo   ============================================
set /p MODE="   Choose 1 or 2: "

if "%MODE%"=="2" (
    python idan_bridge.py --live
) else (
    python idan_bridge.py
)
goto :end

:nopython
echo.
echo   Python was not found. Install it from python.org
echo   and tick "Add python.exe to PATH" during setup.

:end
echo.
pause
