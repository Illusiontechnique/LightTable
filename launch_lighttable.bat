@echo off
echo Starting LightTable System...

:: Use the project's virtual environment
set PYTHON_EXE=c:\Users\jasonhendrik\Documents\illusiontechnique_coding\LightTable\.venv\Scripts\python.exe

cd cv_layer
start "LightTable CV" %PYTHON_EXE% main.py

cd ..\visual_layer
echo Starting Visuals...
echo Note: If Godot isn't in your PATH, you may need to open 'visual_layer/project.godot' manually.
godot --main-scene res://scenes/main.tscn
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Godot executable not found in PATH.
    echo Please open the project manually in Godot and press F5.
)
pause
