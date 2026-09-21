@echo off
REM JitterLab launcher. Usage: jitterlab <command> [args]
REM Commands: status snapshot start stop diff trace presentmon clean pack selftest
REM trace and presentmon need an elevated prompt - see docsLEVATED-STEPS.md
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0JitterLab.ps1" %*
endlocal
