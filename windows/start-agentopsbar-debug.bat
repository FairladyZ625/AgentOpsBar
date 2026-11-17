@echo off
setlocal
python "%~dp0agentopsbar.py"
if errorlevel 1 pause
