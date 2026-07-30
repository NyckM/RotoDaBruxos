@echo off
cd /d "%~dp0"
echo.
echo  RotoDaBruxos
echo  Abrindo em http://localhost:8080
echo.
start "" "http://localhost:8080"
call npm.cmd run start
pause
