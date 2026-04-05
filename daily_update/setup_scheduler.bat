@echo off
REM ============================================================
REM Daily Paper Update - Windows Task Scheduler Setup (PowerShell)
REM Run this script as Administrator to create the scheduled task
REM ============================================================

echo Daily Paper Update - Task Scheduler Setup
echo ==========================================
echo.

REM Check for administrator privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script requires Administrator privileges.
    echo Please right-click and select "Run as administrator"
    pause
    exit /b 1
)

REM Get the directory where this script is located
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

REM Set the PowerShell script path
set "PS_SCRIPT=%SCRIPT_DIR%\daily_update.ps1"

REM Check if PowerShell script exists
if not exist "%PS_SCRIPT%" (
    echo ERROR: daily_update.ps1 not found in %SCRIPT_DIR%
    pause
    exit /b 1
)

echo Script path: %PS_SCRIPT%
echo.

REM Task name
set "TASK_NAME=DailyPaperUpdate"

REM Delete existing task if it exists
schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1

REM Create the scheduled task
REM Schedule for 11:30 Israel time
REM Using 11:30 local time - adjust if your Windows is not set to Israel timezone

echo Creating scheduled task for 11:30 daily...
echo.

schtasks /create ^
    /tn "%TASK_NAME%" ^
    /tr "powershell.exe -ExecutionPolicy Bypass -File \"%PS_SCRIPT%\"" ^
    /sc daily ^
    /st 11:30 ^
    /ru "%USERNAME%" ^
    /rl HIGHEST ^
    /f

if %errorLevel% equ 0 (
    echo.
    echo SUCCESS! Task "%TASK_NAME%" has been created.
    echo The task will run daily at 11:30 local time.
) else (
    echo.
    echo ERROR: Failed to create daily paper update task.
    echo Please check the error message above.
)

echo.
echo ==========================================
echo Setting up Monthly Website Update task...
echo ==========================================
echo.

REM Monthly website update task
set "MONTHLY_TASK_NAME=MonthlyWebsiteUpdate"
set "WEBSITE_SCRIPT=%SCRIPT_DIR%\update_website.ps1"

REM Check if website update script exists
if not exist "%WEBSITE_SCRIPT%" (
    echo WARNING: update_website.ps1 not found in %SCRIPT_DIR%
    echo Skipping monthly website update task.
    goto :done
)

echo Website update script: %WEBSITE_SCRIPT%
echo.

REM Delete existing monthly task if it exists
schtasks /delete /tn "%MONTHLY_TASK_NAME%" /f >nul 2>&1

REM Create monthly task (1st of each month at 12:00)
echo Creating scheduled task for 1st of each month at 12:00...
echo.

schtasks /create ^
    /tn "%MONTHLY_TASK_NAME%" ^
    /tr "powershell.exe -ExecutionPolicy Bypass -File \"%WEBSITE_SCRIPT%\"" ^
    /sc monthly ^
    /d 1 ^
    /st 12:00 ^
    /ru "%USERNAME%" ^
    /rl HIGHEST ^
    /f

if %errorLevel% equ 0 (
    echo.
    echo SUCCESS! Task "%MONTHLY_TASK_NAME%" has been created.
    echo The task will run on the 1st of each month at 12:00.
) else (
    echo.
    echo ERROR: Failed to create monthly website update task.
)

:done
echo.
echo ============================================================
echo Setup complete. To verify tasks:
echo   - Open Task Scheduler (taskschd.msc)
echo   - Look for "%TASK_NAME%" and "%MONTHLY_TASK_NAME%"
echo.
echo To run tasks manually for testing:
echo   schtasks /run /tn "%TASK_NAME%"
echo   schtasks /run /tn "%MONTHLY_TASK_NAME%"
echo.
echo To delete tasks later:
echo   schtasks /delete /tn "%TASK_NAME%" /f
echo   schtasks /delete /tn "%MONTHLY_TASK_NAME%" /f
echo ============================================================
echo.
pause
