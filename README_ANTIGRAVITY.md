# Contexto del proyecto para antigravity

## Objetivo del proyecto

Implementar un experimento de péndulo con una Raspberry Pi Pico W y un MPU-9250 para:

- adquirir aceleración y velocidad angular
- transmitir datos por TCP hacia MATLAB
- estimar parámetros del sistema desde MATLAB
- usar ambos cores del RP2040
- disponer de diagnóstico por UART/USB para depuración

## Hardware principal

- Raspberry Pi Pico W
- IMU MPU-9250 por I2C
- UART externa para depuración
- Analog Discovery 1 usado como interfaz/monitor UART

## Mapeo de pines relevante

### I2C hacia MPU-9250

- `GPIO8` -> SDA
- `GPIO9` -> SCL

### UART de depuración

- `GPIO0` -> TX de la Pico
- `GPIO1` -> RX de la Pico
- `GND` compartida con el instrumento externo

### Cableado esperado con Analog Discovery 1

Para solo escuchar el arranque por UART:

- `Pico GPIO0` -> `AD1 DIO0`
- `Pico GND` -> `AD1 GND`

Si también se quiere enviar texto hacia la Pico:

- `Pico GPIO1` <- `AD1 DIO1`

## Estado funcional esperado del firmware

El firmware principal debe:

- inicializar salida de diagnóstico por UART y/o USB
- emitir mensajes de arranque paso a paso
- inicializar CYW43 para Wi-Fi
- inicializar I2C y detectar el MPU-9250
- crear tareas con afinidad de core usando FreeRTOS SMP
- leer el IMU en un core
- atender Wi-Fi/TCP/LED/diagnóstico en el otro core
- enviar muestras en formato CSV a MATLAB por TCP

## Archivos clave del proyecto

- `Practica_5.c`
  - firmware principal
- `CMakeLists.txt`
  - configuración del proyecto Pico SDK
- `lwipopts.h`
  - configuración mínima de lwIP
- `PicoPendulumReader.m`
  - lectura desde MATLAB
- `tools/uart_ad1_monitor.py`
  - monitor UART con Analog Discovery 1 usando `pydwf`
- `requirements.txt`
  - dependencia Python para `pydwf`

## Estado actual del código

Se hicieron cambios en `Practica_5.c` para agregar diagnósticos de arranque:

- trazas numeradas tipo `BOOT`
- ventana inicial de diagnóstico UART
- mensajes explícitos para stdio, CYW43, I2C, cola/mutex, MPU, Wi-Fi y creación de tareas
- intento de forzar `UART0` a `115200` en `GPIO0/GPIO1`
- salida sin buffering

También se ajustó el monitor Python `tools/uart_ad1_monitor.py` para que sea compatible con la API real instalada de `pydwf`.

## Resultado de depuración hasta ahora

### Lo que sí funcionó

- el proyecto compila correctamente
- se genera `Practica_5.uf2`
- el UF2 se pudo flashear varias veces a la Pico W
- el Analog Discovery 1 es detectado correctamente por `pydwf`
- el monitor UART abre correctamente el dispositivo

### Lo que no funcionó

A pesar de varias pruebas:

- no se recibió ningún byte por UART externa desde la Pico W
- el monitor reportó repetidamente `No UART data received within timeout`

### Interpretación actual

Aún no está demostrado si el problema es:

- el camino físico de señal UART
- el arranque real del firmware en la Pico W
- una diferencia entre UART por GPIO y stdio por USB
- alguna interacción inesperada con la inicialización de stdio/UART en el firmware actual

## Configuración de red prevista

- SSID: `Robot`
- password: `Rave2310`
- puerto TCP: `4242`

Nota: en `CMakeLists.txt` los valores cacheados de Wi-Fi pueden seguir vacíos si no se reconfigura CMake con esos parámetros.

## Diseño lógico del firmware

### Tareas previstas

- `app_main_task`
  - arranque general y creación de tareas
- `mpu_sampling_task`
  - lectura periódica del IMU
- `tcp_server_task`
  - servidor TCP para MATLAB
- `led_status_task`
  - estado visual mediante LED de la Pico W
- `diagnostics_task`
  - heartbeat y estado general

### Indicaciones de afinidad de core

- core 1: adquisición del MPU
- core 0: Wi-Fi, TCP, LED y diagnóstico

## Comandos de host usados durante la depuración

### Compilación

```powershell
cmake --build build -j 4
```

### Flasheo manual por BOOTSEL

```powershell
$vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'RPI-RP2' }
$drive = $vol.DriveLetter + ':'
Copy-Item -Path '.\build\Practica_5.uf2' -Destination ($drive + '\Practica_5.uf2') -Force
```

### Monitor UART con AD1

```powershell
python tools\uart_ad1_monitor.py --device-index 0 --rx-pin 0 --tx-pin 1 --baudrate 115200 --timeout 12 --log-file uart_capture.log
```

## Siguientes pasos recomendados

### Prioridad alta

- validar si la Pico W arranca correctamente con un UF2 oficial conocido
- probar un UF2 oficial de MicroPython para Pico W
- comprobar si aparece un puerto COM por USB
- verificar si hay actividad eléctrica real en `GPIO0` con analizador lógico u osciloscopio

### Prioridad media

- simplificar temporalmente el firmware a un caso mínimo que solo emita por UART en un bucle
- comparar salida por USB CDC versus UART GPIO
- revisar si la inicialización de stdio/UART debería moverse fuera de la tarea y más cerca de `main`

## Enlace externo útil

UF2 oficial recomendado para validar la placa:

- MicroPython Pico W: `https://micropython.org/download/RPI_PICO_W/`

## Resumen corto para handoff

El proyecto está cerca de tener el firmware multitarea y el monitor UART listos, pero está bloqueado por una falla de observabilidad: no se ven mensajes por UART externa aunque el firmware compila y se flashea. Antes de seguir ajustando el firmware principal, conviene validar la placa y el canal de depuración con un UF2 oficial conocido y/o una medición directa del pin `GPIO0`.
