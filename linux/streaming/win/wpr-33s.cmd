@echo off
rem Capture ~80 s of kernel CPU sampling (WPR "CPU" profile) to find which driver's
rem System thread spins a core for ~2.5 s every ~33 s.  Needs an elevated prompt:
rem right-click -> Run as administrator (UAC is the owner's to approve).
rem Output: %TEMP%\wpr-33s\cpu.etl (~2 GB, keep it out of the repo); analyse with wpr-33s.py
set OUT=%TEMP%\wpr-33s
if not exist "%OUT%" mkdir "%OUT%"
wpr -cancel >nul 2>&1
wpr -start CPU -filemode || (echo wpr start failed & pause & exit /b 1)
echo Recording 80 s ...
timeout /t 80 /nobreak >nul
wpr -stop "%OUT%\cpu.etl" "Y700 streaming: 33 s System-thread spike"
echo done: %OUT%\cpu.etl
timeout /t 5 >nul
