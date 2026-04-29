@echo off
echo Starting LightTable System...

cd cv_layer
start python main.py

cd ..\visual_layer
echo Starting Visuals (Ensure Godot is in PATH or specify path here)
start godot --main-scene res://scenes/main.tscn
