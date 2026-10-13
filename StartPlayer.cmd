@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  python -m venv .venv
  if errorlevel 1 goto failed
)
".venv\Scripts\python.exe" -c "import fastapi, uvicorn, usb, mido, websockets" >nul 2>&1
if errorlevel 1 (
  ".venv\Scripts\python.exe" -m pip install --disable-pip-version-check --index-url https://pypi.org/simple -r pc_player\requirements.txt
  if errorlevel 1 goto failed
)
".venv\Scripts\python.exe" -X utf8 pc_player\browser_player.py
if errorlevel 1 goto failed
exit /b 0
:failed
echo Install Python 3.11 x64 and dependencies: .venv\Scripts\python.exe -m pip install -r pc_player\requirements.txt
pause
exit /b 1
