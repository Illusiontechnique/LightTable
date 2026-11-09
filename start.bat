@echo off
setlocal
echo ==========================================
echo    LightTable Unified Launcher
echo ==========================================

:: 1. Configuration
set ROOT=%~dp0
set PYTHON_EXE=%ROOT%.venv\Scripts\python.exe
set GODOT_EXE="C:\Users\jasonhendrik\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.6.2-stable_win64.exe"

:: 2. Start CV Layer (Background)
echo [1/2] Starting CV Layer ...
pushd "%ROOT%cv_layer"
start "LightTable_CV" /B "%PYTHON_EXE%" main.py %*
popd

:: 3. Start Visual Layer (Foreground)
echo [2/2] Starting Visuals ...
pushd "%ROOT%visual_layer"
if exist %GODOT_EXE% (
    %GODOT_EXE% --main-scene res://scenes/main.tscn
) else (
    echo [WARN] Custom Godot path not found, trying system 'godot'...
    godot --main-scene res://scenes/main.tscn
)

:: The CV process can be stopped from the authenticated remote.
echo.
echo Godot exited. CV and web remote continue running; stop them from the remote.
