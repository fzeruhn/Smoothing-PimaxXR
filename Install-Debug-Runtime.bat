@echo off
echo ==========================================
echo Registering Custom PimaxXR Debug Build
echo ==========================================

:: Get the exact path of the JSON file based on where this script is located
set "JSON_PATH=%~dp0bin\x64\debug\pimax-openxr.json"

echo Looking for manifest at: %JSON_PATH%

:: Check if the file actually exists before we break the registry
if not exist "%JSON_PATH%" (
    echo ERROR: Could not find the JSON file! Did you build the project?
    pause
    exit /b
)

:: Apply the registry change (Requires Admin)
REG ADD "HKLM\SOFTWARE\Khronos\OpenXR\1" /v "ActiveRuntime" /t REG_SZ /d "%JSON_PATH%" /f

echo.
echo Success! Your PC is now using the custom debug runtime.
:: Waits 2 seconds so you can see the success message, then auto-closes
timeout /t 2 >nul