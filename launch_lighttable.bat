@echo off
echo Starting LightTable System...

:: Use the project's virtual environment
set PYTHON_EXE=c:\Users\jasonhendrik\Documents\illusiontechnique_coding\LightTable\.venv\Scripts\python.exe

cd cv_layer
start "LightTable CV" %PYTHON_EXE% main.py

cd ..\visual_layer
echo Starting Visuals...
set GODOT_EXE="C:\Users\jasonhendrik\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.6.2-stable_win64.exe"

if exist %GODOT_EXE% (
    %GODOT_EXE% --main-scene res://scenes/main.tscn
) else (
    godot --main-scene res://scenes/main.tscn
    if %ERRORLEVEL% NEQ 0 (
        echo.
        echo [ERROR] Godot executable not found.
        echo Please open 'visual_layer/project.godot' manually in Godot and press F5.
        pause
    )
)
exit
