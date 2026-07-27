@echo off
rem postmarketOS flasher for Samsung Galaxy S5 (SM-G900FD)
rem Phone must be in fastboot mode (lk2nd menu on screen).
cd /d "%~dp0"

set FASTBOOT=fastboot.exe
if exist platform-tools\fastboot.exe set FASTBOOT=platform-tools\fastboot.exe
%FASTBOOT% --version >nul 2>nul
if errorlevel 1 (
  echo [ERROR] fastboot.exe not found.
  echo Download platform-tools and unpack the folder next to this file:
  echo https://developer.android.com/tools/releases/platform-tools
  pause
  exit /b 1
)

if not exist samsung-klte.img (
  echo [ERROR] samsung-klte.img not found next to this script.
  echo Unpack the release zip into this folder.
  pause
  exit /b 1
)

echo Waiting for phone in fastboot mode (lk2nd menu on screen)...
%FASTBOOT% wait-for-device

echo [1/3] Flashing system image (takes a few minutes)...
%FASTBOOT% flash userdata samsung-klte.img
if errorlevel 1 goto err

echo [2/3] Flashing kernel...
%FASTBOOT% flash boot boot.img
if errorlevel 1 goto err

echo [3/3] Rebooting...
%FASTBOOT% reboot

echo.
echo DONE! First boot takes a couple of minutes. Lock screen PIN: 147147
pause
exit /b 0

:err
echo.
echo [ERROR] Flashing failed. If the phone is not detected:
echo  - make sure lk2nd menu is on screen (fastboot mode)
echo  - install WinUSB driver with Zadig: https://zadig.akeo.ie/
pause
exit /b 1
