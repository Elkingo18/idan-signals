@echo off
title Idans Money Club - Setup
color 0E
echo.
echo   ============================================================
echo      Idans Money Club  -  installing your gold bot
echo      Demo money only. Nothing here touches real funds.
echo   ============================================================
echo.
echo   Getting the installer, one moment...
echo.
set "D=%USERPROFILE%\IdanClub"
if not exist "%D%" mkdir "%D%"
set "PS1=%D%\club_setup.ps1"
set "URL=https://elkingo18.github.io/idan-signals/club/downloads/club_setup.ps1"

if exist "%PS1%" del /q "%PS1%"
where curl >nul 2>&1
if %errorlevel%==0 curl -s -L -o "%PS1%" "%URL%"
if not exist "%PS1%" powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -Uri '%URL%' -OutFile '%PS1%' -UseBasicParsing } catch { }"

if not exist "%PS1%" (
  echo   Could not download the installer.
  echo   Check your internet connection and run this file again.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
echo   Keep this window open until you have copied your key above.
echo.
pause
