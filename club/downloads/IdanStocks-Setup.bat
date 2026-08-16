@echo off
title Idans Money Club - Stocks Feed Setup
echo.
echo   ===== Idans Money Club - Stocks (paper) Setup =====
echo   Fetching the installer, one moment...
echo.
set "D=%USERPROFILE%\IdanClub"
if not exist "%D%" mkdir "%D%"
curl -s -L -o "%D%\stocks_setup.ps1" https://elkingo18.github.io/idan-signals/club/downloads/stocks_setup.ps1
if not exist "%D%\stocks_setup.ps1" (
  echo   Download failed. Check your internet connection and run this file again.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%D%\stocks_setup.ps1"
echo.
pause
