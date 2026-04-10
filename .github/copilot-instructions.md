# Directrices del Proyecto

## Descripción General

Sistema embebido de adquisición de datos en tiempo real para un péndulo, ejecutándose en **Raspberry Pi Pico W** (RP2040 dual-core ARM Cortex-M0+). Transmite datos IMU de 6 ejes (MPU-9250) por TCP/IP a un host MATLAB para estimación de parámetros. Usa **FreeRTOS SMP** en ambos núcleos.

## Arquitectura

### Distribución de Tareas (FreeRTOS SMP)

| Tarea | Núcleo | Prioridad | Rol |
|-------|--------|-----------|-----|
| `app_main_task` | 0 | 4 | Arranque, crea las demás tareas y termina |
| `mpu_sampling_task` | 1 | 3 | Muestreo IMU a 200 Hz → cola |
| `tcp_server_task` | 0 | 2 | Servidor TCP en puerto 4242, transmite CSV |
| `led_status_task` | 0 | 1 | Estado visual mediante LED CYW43 |
| `diagnostics_task` | 0 | 1 | Registro de heartbeat cada 5 s |

### Interfaces de Hardware

- **I2C** (GPIO8 SDA, GPIO9 SCL @ 400 kHz) → MPU-9250
- **UART** (GPIO0 TX, GPIO1 RX @ 115200) → Salida de depuración
- **WiFi** (CYW43439) → Transmisión TCP al cliente MATLAB

### Sincronización

- `imu_mutex` protege el acceso I2C
- Cola FreeRTOS (profundidad 64) para productor/consumidor de muestras IMU
- Flags volátiles para señalización entre tareas (`streaming_enabled`, `wifi_connected`)

### Protocolo TCP

MATLAB envía comandos de texto: `PING`, `START`, `STOP`, `BIAS`, `RATE <hz>`. Formato de datos: `<t_ms>,<ax>,<ay>,<az>,<gx>,<gy>,<gz>\n`.

## Compilación y Pruebas

**SDK:** Pico SDK 2.2.0 · **Toolchain:** GCC ARM 14.2 · **Build:** Ninja

```bash
# Configurar (hay que definir credenciales WiFi)
cmake -B build -DWIFI_SSID="Robot" -DWIFI_PASSWORD="Rave2310" .

# Compilar
cmake --build build -j4
# O usar la tarea de VS Code: "Compile Project"

# Flashear vía BOOTSEL
# Mantener BOOTSEL, pulsar Reset, copiar build/Practica_5.uf2 a la unidad RPI-RP2
# O usar la tarea de VS Code: "Run Project" (picotool)
```

**Dos targets de compilación:**
- `Practica_5` — Firmware completo (IMU + WiFi + TCP)
- `uart_test` — Solo prueba de escaneo/conexión WiFi

**Cliente MATLAB:** Instanciar objeto `PicoPendulumReader`, llamar `step()` en un bucle.

**Monitoreo UART:** `python tools/uart_ad1_monitor.py` (Digilent AD1) o `tools/serial_monitor.ps1`.

## Estilo de Código

- C99, sin C++ en el firmware
- `snake_case` para funciones, variables y tipos
- `static` para globales privadas del módulo y funciones auxiliares
- Tipos enum para estados discretos (ej. `led_status_t`)
- Retornos booleanos para operaciones I2C/TCP (true = éxito)
- `setvbuf(stdout, NULL, _IONBF, 0)` — stdio sin buffer para diagnósticos

## Convenciones

- **Manejo de errores:** Bucles de reintento para inicialización no crítica (WiFi, detección MPU). Fallos suaves — continúa sin MPU si no está disponible.
- **Diagnósticos:** Trazas de pasos de arranque al inicio, `log_system_status()` para volcado de estado, contadores de fallos para análisis post-mortem.
- **Credenciales WiFi** se configuran como variables de caché CMake (`WIFI_SSID`, `WIFI_PASSWORD`, `WIFI_TCP_PORT`).
- **Solo salida UART** — USB CDC está deshabilitado. Esto es intencional para aislamiento durante depuración WiFi.

## Trampas Comunes

- Las credenciales WiFi persisten en la caché de CMake. Re-ejecutar `cmake -B build -DWIFI_SSID=...` para cambiarlas.
- I2C a 400 kHz necesita pull-ups externos (10 kΩ en GPIO8/GPIO9) para fiabilidad.
- El WHO_AM_I del MPU-9250 acepta `0x71` o `0x73` (variantes del chip).
- La calibración de bias del giroscopio es bajo demanda vía comando `BIAS` (~4 s, 200 muestras).
- Los reintentos WiFi están limitados a 10 — continúa silenciosamente sin red si no encuentra el SSID.

## Archivos Clave

| Archivo | Propósito |
|---------|-----------|
| `Practica_5.c` | Firmware principal: todas las tareas FreeRTOS, driver IMU, servidor TCP |
| `CMakeLists.txt` | Configuración de build: SDK, FreeRTOS, lwIP, flags del compilador |
| `FreeRTOSConfig.h` | Configuración del kernel: tick rate (1 kHz), heap (64 KB), SMP, verificación de stack |
| `lwipopts.h` | Configuración de lwIP: buffers TCP, API de sockets, DHCP |
| `uart_test.c` | Target de prueba mínimo para diagnóstico WiFi |
| `PicoPendulumReader.m` | System object de MATLAB: cliente TCP para adquisición de datos |
| `tools/uart_ad1_monitor.py` | Monitor UART vía Digilent Analog Discovery 1 |
| `README_ANTIGRAVITY.md` | Notas de depuración y estado actual |
