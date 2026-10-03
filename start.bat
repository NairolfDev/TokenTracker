@echo off
setlocal
cd /d "%~dp0"
title TokenTracker - Start

if not exist "venv\Scripts\python.exe" (
    echo Erstelle Python-Umgebung ...
    py -3 -m venv venv
    if errorlevel 1 (
        python -m venv venv
        if errorlevel 1 goto :failed
    )
)

"venv\Scripts\python.exe" -c "import hashlib,pathlib,sys; r=pathlib.Path('requirements.txt'); m=pathlib.Path('venv/.requirements.sha256'); sys.exit(0 if m.exists() and m.read_text()==hashlib.sha256(r.read_bytes()).hexdigest() else 1)" >nul 2>&1
if errorlevel 1 (
    echo Installiere bzw. aktualisiere Abhaengigkeiten ...
    "venv\Scripts\python.exe" -m pip install -r requirements.txt
    if errorlevel 1 goto :failed
    "venv\Scripts\python.exe" -c "import hashlib,pathlib; pathlib.Path('venv/.requirements.sha256').write_text(hashlib.sha256(pathlib.Path('requirements.txt').read_bytes()).hexdigest())"
)

"venv\Scripts\python.exe" -c "import customtkinter,requests,playwright,PIL,pystray" >nul 2>&1
if errorlevel 1 goto :failed
start "TokenTracker" "venv\Scripts\pythonw.exe" main.py
exit /b 0

:failed
echo.
echo TokenTracker konnte nicht gestartet werden.
echo Bitte pruefe Python und deine Internetverbindung. Die Fehlermeldung steht oben.
pause
exit /b 1
