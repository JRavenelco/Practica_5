# Práctica 5 — Adquisición de Datos de Péndulo con Raspberry Pi Pico W

Sistema embebido de adquisición de datos en tiempo real para un péndulo. La Raspberry Pi Pico W muestrea un IMU de 6 ejes (MPU-9250) a 200 Hz y transmite los datos por TCP/IP a MATLAB/Simulink. Un actuador lineal Actuonix L12 controlado desde la PC actúa como shaker para excitación.

---

## Tabla de Contenidos

1. [Requisitos de Hardware](#1-requisitos-de-hardware)
2. [Requisitos de Software](#2-requisitos-de-software)
3. [Instalación del Entorno de Desarrollo](#3-instalación-del-entorno-de-desarrollo)
4. [Conexión a la Red WiFi de Juriquilla](#4-conexión-a-la-red-wifi-de-juriquilla)
5. [Flashear el Firmware](#5-flashear-el-firmware)
6. [Ver la IP de la Pico W por USB](#6-ver-la-ip-de-la-pico-w-por-usb)
7. [Adquisición de Datos en MATLAB](#7-adquisición-de-datos-en-matlab)
8. [Simulink — Bloques de Sistema](#8-simulink--bloques-de-sistema)
9. [Control del Actuador LAC (Shaker)](#9-control-del-actuador-lac-shaker)
10. [Compilación del Firmware (Avanzado)](#10-compilación-del-firmware-avanzado)
11. [Estructura del Proyecto](#11-estructura-del-proyecto)
12. [Solución de Problemas](#12-solución-de-problemas)

---

## 1. Requisitos de Hardware

| Componente | Descripción |
|---|---|
| Raspberry Pi Pico W | Microcontrolador RP2040 con WiFi CYW43439 |
| MPU-9250 | IMU de 9 ejes (acelerómetro + giroscopio + magnetómetro) |
| Actuonix L12 | Actuador lineal (50 mm de carrera) — shaker |
| LAC Board | Controlador USB para el L12 (Actuonix) |
| Cable USB micro-B | Para flashear firmware y ver diagnósticos |
| Cable USB mini-B | Para conectar el LAC a la PC |
| Pull-ups I2C | Resistencias de 10 kΩ en GPIO8 (SDA) y GPIO9 (SCL) |
| Router WiFi | Red compartida entre la Pico W y la PC |

### Conexiones I2C (Pico W → MPU-9250)

| Pico W Pin | MPU-9250 Pin |
|---|---|
| GPIO8 (SDA) | SDA |
| GPIO9 (SCL) | SCL |
| 3V3 (OUT) | VCC |
| GND | GND |

---

## 2. Requisitos de Software

### En la PC del alumno

| Software | Versión Mínima | Uso |
|---|---|---|
| MATLAB | R2024b+ | Adquisición de datos y análisis |
| Simulink | (incluido en MATLAB) | Modelos en tiempo real |
| Python | 3.12.x | Control del actuador LAC desde MATLAB |
| PuTTY o terminal serial | Cualquiera | Ver la IP de la Pico W por USB |

### Solo para compilar firmware (no requerido para alumnos)

| Software | Versión |
|---|---|
| VS Code + extensión Raspberry Pi Pico | Última |
| Pico SDK | 2.2.0 |
| GCC ARM | 14.2 |
| CMake + Ninja | 3.13+ / 1.12+ |

---

## 3. Instalación del Entorno de Desarrollo

### 3.1 Python 3.12 (para el actuador LAC)

> **MATLAB R2025b no soporta Python 3.13+.** Usar Python 3.12.

1. Descargar Python 3.12.x de https://www.python.org/downloads/
2. Instalar marcando **"Add Python to PATH"**
3. Abrir un terminal y crear el entorno virtual:

```powershell
cd C:\Users\<tu_usuario>\Desktop\Practica_5
C:\Python312\python.exe -m venv .venv312
.\.venv312\Scripts\Activate.ps1
pip install pyusb libusb-package
```

### 3.2 Configurar Python en MATLAB

Abrir MATLAB y ejecutar **una sola vez**:

```matlab
pyenv('Version', 'C:\Users\<tu_usuario>\Desktop\Practica_5\.venv312\Scripts\python.exe')
```

Verificar:

```matlab
>> pyenv

ans = 
  PythonEnvironment with properties:
          Version: "3.12"
           Status: NotLoaded
```

### 3.3 Instalar el driver del LAC (Actuonix)

1. Ejecutar el instalador `Actuonix LAC Configuration Utility-2.4-Setup.exe` (incluido en el repositorio o descargarlo de https://www.actuonix.com/lac)
2. Conectar el LAC por USB y verificar que Windows lo reconoce en el Administrador de Dispositivos como dispositivo USB (VID: `04D8`, PID: `FC5F`)
3. **No es necesario** abrir la utilidad de Actuonix — el control se hace desde Python/MATLAB

### 3.4 Instalar PuTTY (para ver la IP)

Descargar de https://www.putty.org/ o usar cualquier terminal serial (TeraTerm, Arduino Serial Monitor, etc.)

---

## 4. Conexión a la Red WiFi de Juriquilla

La Pico W se conecta automáticamente al SSID configurado en el firmware. Para la red del laboratorio de Juriquilla:

### 4.1 Configurar la red en la PC

1. Conectar la PC a la **misma red WiFi** que la Pico W
2. El SSID y contraseña del firmware están configurados como:
   - **SSID:** `Robot`
   - **Contraseña:** `Rave2310`
3. Conectar la PC a la red `Robot` con la contraseña `Rave2310`

### 4.2 Si necesitan cambiar la red WiFi

Si la red del laboratorio cambia, hay que **recompilar el firmware** con las nuevas credenciales (ver [Sección 10](#10-compilación-del-firmware-avanzado)):

```powershell
cmake -B build -DWIFI_SSID="NuevoSSID" -DWIFI_PASSWORD="NuevaContraseña" .
cmake --build build -j4
```

Y volver a flashear el archivo `.uf2` generado.

### 4.3 Verificar conectividad

Una vez que la Pico W está conectada y tienen su IP (ver [Sección 6](#6-ver-la-ip-de-la-pico-w-por-usb)):

```powershell
Test-NetConnection -ComputerName <IP_DE_LA_PICO> -Port 4242
```

Debe decir `TcpTestSucceeded : True`.

---

## 5. Flashear el Firmware

El firmware ya está precompilado en la carpeta `build/`. **No necesitan compilar nada.**

### Archivos `.uf2` disponibles

| Archivo | Uso |
|---|---|
| `build/Practica_5.uf2` | **Firmware principal** — IMU + WiFi + TCP |
| `build/uart_test.uf2` | Prueba de WiFi solamente (sin IMU) |
| `build/mpu_test.uf2` | Prueba de I2C/MPU solamente (sin WiFi) |

### Pasos para flashear

1. **Desconectar** el cable USB de la Pico W
2. **Mantener presionado** el botón **BOOTSEL** en la Pico W
3. **Conectar** el cable USB **sin soltar** BOOTSEL
4. **Soltar** BOOTSEL — debe aparecer una unidad USB llamada **RPI-RP2** en el explorador de archivos
5. **Copiar** el archivo `build/Practica_5.uf2` a la unidad **RPI-RP2**
6. La Pico W se reiniciará automáticamente y comenzará a ejecutar el firmware

```powershell
# O desde PowerShell:
Copy-Item build\Practica_5.uf2 -Destination D:\ 
# (donde D: es la unidad RPI-RP2)
```

---

## 6. Ver la IP de la Pico W por USB

El firmware imprime la dirección IP asignada por DHCP a través del **puerto USB serial** (CDC). Para verla:

### Opción A: PuTTY

1. Conectar la Pico W por USB (sin BOOTSEL)
2. Abrir el **Administrador de Dispositivos** → **Puertos (COM y LPT)**
3. Buscar el puerto COM de la Pico (ej. `COM5`, `USB Serial Device`)
4. Abrir **PuTTY**:
   - Connection type: **Serial**
   - Serial line: **COM5** (el que encontraron)
   - Speed: **115200**
   - Click **Open**
5. Presionar el botón **Reset** de la Pico W (o desconectar/reconectar USB)
6. Verán la secuencia de arranque:

```
=== Practica_5 boot ===
[BOOT 01] app_main_task started
[BOOT 02] starting CYW43 init
[BOOT 03] CYW43 init complete
[BOOT 04] starting I2C init
[BOOT 05] I2C init complete
I2C bus scan on i2c0 (SDA=8, SCL=9):
  Device found at 0x68
...
[BOOT 10] starting Wi-Fi connection loop
Connecting to Wi-Fi SSID 'Robot' (auth=2, timeout=30s)...
Wi-Fi connected! IP: 192.168.1.81      ← ESTA ES LA IP
[BOOT 11] Wi-Fi connected
...
TCP server listening on port 4242
```

7. **Anotar la IP** (ej. `192.168.1.81`) — la necesitarán en MATLAB

### Opción B: PowerShell (sin PuTTY)

```powershell
# Cambiar COM5 por el puerto que corresponda
powershell -ExecutionPolicy Bypass -File tools\serial_monitor.ps1 -Port COM5
```

### Opción C: Arduino IDE Serial Monitor

1. Abrir Arduino IDE → Herramientas → Monitor Serie
2. Seleccionar el puerto COM correcto y baudrate **115200**
3. Reset la Pico W

> **Nota:** Si la Pico W no puede conectarse al WiFi (SSID no encontrado, contraseña incorrecta), reintentará 10 veces y continuará sin red. En ese caso no habrá IP y no podrán usar TCP.

---

## 7. Adquisición de Datos en MATLAB

### 7.1 Conexión básica

```matlab
cd('C:\Users\<tu_usuario>\Desktop\Practica_5')

% Crear el reader con la IP de la Pico W
reader = PicoPendulumReader('Host', '192.168.1.81', 'Port', 4242, 'Rate', 200);

% Iniciar (se conecta y envía START automáticamente)
setup(reader);

% Leer una muestra: [t, ax, ay, az, gx, gy, gz, mx, my, mz]
[t, ax, ay, az, gx, gy, gz, mx, my, mz] = reader();

% Adquirir N muestras
N = 1000;
data = zeros(N, 10);
for i = 1:N
    [t, ax, ay, az, gx, gy, gz, mx, my, mz] = reader();
    data(i,:) = [t, ax, ay, az, gx, gy, gz, mx, my, mz];
end

% Liberar conexión
release(reader);
```

### 7.2 Formato de datos

Cada muestra contiene 10 valores:

| Campo | Unidad | Descripción |
|---|---|---|
| `t` | segundos | Timestamp (ms del microcontrolador / 1000) |
| `ax, ay, az` | g | Aceleración en 3 ejes |
| `gx, gy, gz` | °/s | Velocidad angular en 3 ejes |
| `mx, my, mz` | µT | Campo magnético en 3 ejes |

### 7.3 Comandos TCP disponibles

Desde MATLAB se pueden enviar comandos al servidor TCP de la Pico:

| Comando | Respuesta | Descripción |
|---|---|---|
| `PING` | `PONG` | Verificar conexión |
| `START` | `OK START` | Iniciar streaming de datos |
| `STOP` | `OK STOP` | Detener streaming |
| `RATE <hz>` | `OK RATE <hz>` | Cambiar tasa de muestreo |
| `BIAS` | `OK BIAS` | Calibrar giroscopio (~4 s) |

---

## 8. Simulink — Bloques de Sistema

### 8.1 PicoPendulumReader (lectura del IMU)

1. En Simulink, agregar un bloque **MATLAB System**
2. Escribir `PicoPendulumReader` como nombre de la clase
3. Configurar propiedades:
   - `Host`: IP de la Pico W (ej. `192.168.1.81`)
   - `Port`: `4242`
   - `Rate`: `200` (Hz)
4. **Salidas** (10 puertos): `t, ax, ay, az, gx, gy, gz, mx, my, mz`
5. Sample time: automático (1/Rate = 5 ms)

### 8.2 LACActuatorBlock (control del shaker)

1. En Simulink, agregar un bloque **MATLAB System**
2. Escribir `LACActuatorBlock` como nombre de la clase
3. Configurar propiedades:
   - `Rate`: `50` (Hz, frecuencia de comandos al actuador)
   - `StrokeMM`: `50` (carrera del actuador en mm)
   - `RetractOnStop`: `true` (retrae al parar simulación)
4. **Entrada**: posición deseada en % (0–100)
5. **Salida**: posición medida (feedback) en %

#### Ejemplo: excitación sinusoidal

Conectar un bloque **Sine Wave** a la entrada del `LACActuatorBlock`:
- Amplitude: `20`
- Bias: `50`
- Frequency: `2*pi*1` (1 Hz)

Esto moverá el actuador entre 30% y 70% de su carrera a 1 Hz.

### 8.3 Modelo completo

```
[Sine Wave] → [LACActuatorBlock] → [Scope (feedback)]
                                     
[PicoPendulumReader] → [ax] → [Scope (aceleración)]
                     → [gx] → [Scope (giroscopio)]
                     → ...
```

Ambos bloques funcionan simultáneamente en el mismo modelo de Simulink.

---

## 9. Control del Actuador LAC (Shaker)

### 9.1 Desde MATLAB (sin Simulink)

```matlab
cd('C:\Users\<tu_usuario>\Desktop\Practica_5')

shaker = LACShaker();
shaker.connect();

% Mover a posición fija
shaker.move(50);            % 50% de la carrera

% Leer posición actual
pos = shaker.feedback();    % en %
mm  = shaker.feedbackMM();  % en mm

% Oscilación sinusoidal (bloqueante)
shaker.sine(1.0, 40, 10);  % 1 Hz, 40% amplitud, 10 segundos

% Barrido de frecuencia (chirp)
shaker.chirp(0.5, 5.0, 40, 30);  % 0.5→5 Hz, 40% amp, 30 s

% Oscilación continua (no-bloqueante)
shaker.startSine(1.0, 40);
pause(10);
shaker.stop();

% Desconectar (retrae a 0%)
shaker.disconnect();
```

### 9.2 Desde Python (CLI)

```powershell
# Activar entorno
.\.venv312\Scripts\Activate.ps1

# Sinusoidal: 2 Hz, 20% amplitud, 10 segundos
python tools/lac_shaker.py sine --freq 2.0 --amp 20 --duration 10

# Chirp: 0.5 → 5 Hz
python tools/lac_shaker.py chirp --f0 0.5 --f1 5.0 --amp 30 --duration 30

# Mover a posición fija
python tools/lac_shaker.py move --position 75

# Leer estado
python tools/lac_shaker.py status
```

---

## 10. Compilación del Firmware (Avanzado)

> Solo necesario si se modifican las credenciales WiFi o el código fuente.

### Requisitos

- VS Code con extensión **Raspberry Pi Pico**
- Pico SDK 2.2.0 (se instala con la extensión)
- GCC ARM 14.2 (se instala con la extensión)

### Comandos

```powershell
# Configurar (primera vez o al cambiar credenciales)
cmake -B build -DWIFI_SSID="Robot" -DWIFI_PASSWORD="Rave2310" .

# Compilar
cmake --build build -j4

# El firmware queda en build/Practica_5.uf2
```

### Targets de compilación

| Target | Archivo fuente | Salida |
|---|---|---|
| `Practica_5` | `Practica_5.c` | `build/Practica_5.uf2` |
| `uart_test` | `uart_test.c` | `build/uart_test.uf2` |
| `mpu_test` | `mpu_test.c` | `build/mpu_test.uf2` |

---

## 11. Estructura del Proyecto

```
Practica_5/
├── Practica_5.c              # Firmware principal (FreeRTOS SMP + IMU + WiFi + TCP)
├── uart_test.c               # Test de WiFi (sin IMU)
├── mpu_test.c                # Test de I2C/MPU (sin WiFi)
├── CMakeLists.txt            # Configuración de build (SDK, FreeRTOS, lwIP)
├── FreeRTOSConfig.h          # Configuración del kernel FreeRTOS
├── lwipopts.h                # Configuración del stack TCP/IP (lwIP)
├── pico_sdk_import.cmake     # Helper del SDK
│
├── PicoPendulumReader.m      # MATLAB System object — cliente TCP para datos IMU
├── LACActuatorBlock.m        # MATLAB System object — bloque Simulink para el actuador
├── LACShaker.m               # MATLAB handle class — control del shaker desde scripts
├── PendulumFusion.m          # Fusión sensorial para estimación de estado del péndulo
├── crear_modelo_pendulo.m    # Creación del modelo de péndulo
├── pendulum_analysis.m       # Análisis de datos y estimación de parámetros
├── shaker_acquisition.m      # Adquisición combinada: shaker + IMU
├── test_shaker_matlab.m      # Test del shaker desde MATLAB
├── respuesta_segundo_orden.slx  # Modelo Simulink
│
├── tools/
│   ├── lac_controller.py     # Driver USB del actuador LAC (pyusb)
│   ├── lac_shaker.py         # CLI para el shaker (sine, chirp, step, move)
│   ├── test_lac_setup.py     # Test de verificación del LAC
│   ├── list_usb.py           # Listar dispositivos USB
│   ├── serial_monitor.ps1    # Monitor serial (PowerShell)
│   ├── serial_read.ps1       # Lector serial simple
│   ├── flash_uf2.ps1         # Flasheo automático de .uf2
│   └── uart_ad1_monitor.py   # Monitor UART vía Digilent Analog Discovery 1
│
├── build/
│   ├── Practica_5.uf2        # Firmware principal precompilado
│   ├── uart_test.uf2         # Test WiFi precompilado
│   └── mpu_test.uf2          # Test I2C precompilado
│
├── requirements.txt          # Dependencias Python (pyusb, libusb-package)
└── README.md                 # ← Este archivo
```

---

## 12. Solución de Problemas

### La Pico W no aparece como puerto COM

- Verificar que el cable USB es de **datos** (no solo carga)
- En el Administrador de Dispositivos, buscar bajo "Puertos (COM y LPT)"
- Si no aparece, flashear de nuevo el `.uf2` vía BOOTSEL

### No veo la IP en el monitor serial

- Verificar que la PC y la Pico W están en la misma red WiFi (`Robot`)
- Presionar **Reset** en la Pico W y observar los mensajes desde el inicio
- Si muestra `Wi-Fi connection failed`, verificar que el router está encendido y el SSID es correcto
- La Pico reintenta 10 veces con 5 s entre intentos

### MATLAB no puede conectarse al TCP

```
Cannot create a communication link with the remote server
```

- Verificar que la IP es correcta: `Test-NetConnection -ComputerName <IP> -Port 4242`
- Verificar que la PC está en la red `Robot`
- Verificar que el firewall de Windows no está bloqueando el puerto 4242
- Reiniciar la Pico W (desconectar/reconectar USB)

### Error de Python en MATLAB

```
Python version X.XX is not supported
```

- Usar Python 3.12: `pyenv('Version', '<ruta>\.venv312\Scripts\python.exe')`
- Reiniciar MATLAB después de cambiar `pyenv`

### El actuador LAC no responde

- Verificar que el LAC está conectado por USB y con alimentación
- Instalar la utilidad de Actuonix (instala los drivers USB necesarios)
- Verificar con Python:

```powershell
.\.venv312\Scripts\Activate.ps1
python tools/test_lac_setup.py --live
```

### Error `WinError 193` al usar el LAC

- Esto ocurre si se intenta usar `mpusbapi.dll` (32-bit) con Python 64-bit
- Solución: ya está resuelto — el código usa `pyusb` que no depende de la DLL

### El giroscopio tiene drift

- Enviar comando `BIAS` para calibrar (toma ~4 segundos, 200 muestras)
- En MATLAB: `writeline(reader.tcp, "BIAS")` (antes de iniciar streaming)

---

## Créditos

Práctica 5 — Ingeniería Mecatrónica, UNAM Campus Juriquilla  
Adquisición de datos con Raspberry Pi Pico W + FreeRTOS SMP
