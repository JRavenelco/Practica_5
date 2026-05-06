"""
imu_test_micro.py — Universal IMU detector/streamer for MicroPython (RP2040)

Paso 1: Detectar que IMU está conectada al bus I2C
Paso 2: Inicializar el sensor
Paso 3: Leer y mostrar datos en CSV por USB serial

Funciona con: MPU-6050, MPU-6500, MPU-9250/9255, ICM-20948,
              LSM6DS3/DSO, BMI160, ADXL345, y magnetómetros comunes.

Conexión:
  Pico GP8  (pin 11) → IMU SDA
  Pico GP9  (pin 12) → IMU SCL
  Pico 3V3  (pin 36) → IMU VCC
  Pico GND  (pin 38) → IMU GND

Abrir monitor serial a 115200 baud para ver los datos.
"""
import utime as time
from machine import I2C, Pin
import struct

# ============================================================
#  CONFIGURACIÓN
# ============================================================
I2C_ID = 0           # i2c0 → GP8=SDA, GP9=SCL
I2C_FREQ = 400000    # 400 kHz
SDA_PIN = 8
SCL_PIN = 9
SAMPLE_RATE_MS = 10  # 100 Hz

# ============================================================
#  UTILIDADES I2C
# ============================================================
class I2CDevice:
    """Wrapper para leer/escribir registros en un dispositivo I2C."""

    def __init__(self, i2c, addr):
        self.i2c = i2c
        self.addr = addr

    def read_reg(self, reg, n=1):
        """Leer n bytes desde el registro 'reg'."""
        self.i2c.writeto(self.addr, bytes([reg]))
        return self.i2c.readfrom(self.addr, n)

    def read_reg_int(self, reg):
        """Leer un byte como entero."""
        return self.read_reg(reg, 1)[0]

    def write_reg(self, reg, val):
        """Escribir un byte en el registro 'reg'."""
        self.i2c.writeto(self.addr, bytes([reg, val]))

    def read_int16(self, reg_h):
        """Leer 2 bytes (big-endian) desde reg_h, devolver int16."""
        data = self.read_reg(reg_h, 2)
        return struct.unpack(">h", data)[0]

    def read_int16_pair(self, reg_h, count=3):
        """Leer pares de int16 (ax, ay, az) desde reg_h."""
        data = self.read_reg(reg_h, count * 2)
        return struct.unpack(">" + "h" * count, data)


def scan_bus(i2c):
    """Escanear bus I2C y devolver lista de direcciones encontradas."""
    devices = i2c.scan()
    print(f"\n[ESCANEO] {len(devices)} dispositivo(s) en bus I2C:")
    for addr in devices:
        print(f"  0x{addr:02X}")
    return devices


# ============================================================
#  TABLA DE SENSORES
# ============================================================
# Cada entrada: (nombre, dirección, registro_WHO_AM_I, valor_esperado, familia)
IMU_PROBES = [
    # InvenSense / TDK
    ("MPU-6050",  0x68, 0x75, 0x68, "mpu"),
    ("MPU-6500",  0x68, 0x75, 0x70, "mpu"),
    ("MPU-9250",  0x68, 0x75, 0x71, "mpu"),
    ("MPU-9255",  0x68, 0x75, 0x73, "mpu"),
    ("ICM-20948", 0x68, 0x00, 0xEA, "icm20948"),
    ("ICM-20948", 0x69, 0x00, 0xEA, "icm20948"),
    # ST
    ("LSM6DS3",   0x6A, 0x0F, 0x69, "lsm6ds"),
    ("LSM6DS3",   0x6B, 0x0F, 0x69, "lsm6ds"),
    ("LSM6DSO",   0x6A, 0x0F, 0x6C, "lsm6ds"),
    ("LSM6DSO",   0x6B, 0x0F, 0x6C, "lsm6ds"),
    ("LSM6DSR",   0x6A, 0x0F, 0x6B, "lsm6ds"),
    ("LSM6DSR",   0x6B, 0x0F, 0x6B, "lsm6ds"),
    # Bosch
    ("BMI160",    0x68, 0x00, 0xD1, "bmi160"),
    ("BMI160",    0x69, 0x00, 0xD1, "bmi160"),
    # Analog Devices
    ("ADXL345",   0x53, 0x00, 0xE5, "adxl345"),
]

# Magnetómetros secundarios
MAG_PROBES = [
    ("AK8963",   0x0C, 0x00, 0x48, "ak8963"),
    ("AK09911",  0x0C, 0x00, 0x05, "ak09911"),
    ("AK09912",  0x0C, 0x00, 0x09, "ak09912"),
    ("BMM150",   0x10, 0x32, 0x32, "bmm150"),
    ("HMC5883L", 0x1E, 0x0A, 0x48, "hmc5883l"),
    ("QMC5883L", 0x0D, 0x0D, 0xFF, "qmc5883l"),
]


# ============================================================
#  DETECCIÓN
# ============================================================
def probe_device(dev, name, who_reg, who_val):
    """Verificar si un dispositivo responde al WHO_AM_I esperado."""
    try:
        val = dev.read_reg_int(who_reg)
        return val == who_val
    except OSError:
        return False


def detect_imu(i2c, scan_result):
    """Detectar qué IMU (y magnetómetro) está conectado."""
    found = []

    for name, addr, who_reg, who_val, family in IMU_PROBES:
        if addr not in scan_result:
            continue
        dev = I2CDevice(i2c, addr)
        if probe_device(dev, name, who_reg, who_val):
            found.append((name, addr, family))
            print(f"  ✓ {name} detectado en 0x{addr:02X}")
            break
    else:
        print("  ✗ No se detectó ninguna IMU conocida")

    mag = None
    for name, addr, who_reg, who_val, family in MAG_PROBES:
        if addr not in scan_result:
            continue
        dev = I2CDevice(i2c, addr)
        if probe_device(dev, name, who_reg, who_val):
            mag = (name, addr, family)
            print(f"  ✓ Magnetómetro {name} detectado en 0x{addr:02X}")
            break

    return found, mag


# ============================================================
#  INICIALIZACIÓN POR FAMILIA
# ============================================================
def init_mpu(dev, name):
    """Inicializar MPU-6050/6500/9250."""
    dev.write_reg(0x6B, 0x80)  # reset
    time.sleep_ms(100)
    dev.write_reg(0x6B, 0x01)  # sleep off, PLL X gyro
    dev.write_reg(0x19, 0x04)  # SMPLRT_DIV → ~200 Hz
    dev.write_reg(0x1A, 0x03)  # CONFIG, DLPF 44 Hz
    dev.write_reg(0x1B, 0x00)  # GYRO_CONFIG ±250°/s
    dev.write_reg(0x1C, 0x00)  # ACCEL_CONFIG ±2g
    dev.write_reg(0x1D, 0x03)  # ACCEL_CONFIG2 DLPF
    dev.write_reg(0x37, 0x02)  # INT_PIN_CFG: I2C bypass
    print(f"  {name}: ±2g, ±250°/s, ~200 Hz, I2C bypass ON")
    return True


def read_mpu(dev, mag_dev=None):
    """Leer MPU: accel(3), temp(1), gyro(3) = 14 bytes."""
    data = dev.read_reg(0x3B, 14)
    ax, ay, az, temp, gx, gy, gz = struct.unpack(">hhhhhhh", data)
    # Escalas: accel ±2g = 16384 LSB/g, gyro ±250°/s = 131 LSB/(°/s)
    ax_f = ax / 16384.0
    ay_f = ay / 16384.0
    az_f = az / 16384.0
    gx_f = gx / 131.0
    gy_f = gy / 131.0
    gz_f = gz / 131.0
    mx = my = mz = 0.0
    if mag_dev:
        mx, my, mz = read_ak8963(mag_dev)
    return ax_f, ay_f, az_f, gx_f, gy_f, gz_f, mx, my, mz


def init_ak8963(dev):
    """Inicializar AK8963 magnetómetro."""
    dev.write_reg(0x0B, 0x01)  # soft reset
    time.sleep_ms(100)
    dev.write_reg(0x0A, 0x16)  # CNTL1: 100 Hz, 16-bit
    time.sleep_ms(10)
    print("  AK8963: 100 Hz, 16-bit, continuous mode")
    return True


def read_ak8963(dev):
    """Leer AK8963 magnetómetro."""
    st1 = dev.read_reg_int(0x02)
    if not (st1 & 0x01):
        return 0.0, 0.0, 0.0
    data = dev.read_reg(0x03, 7)
    mx, my, mz = struct.unpack("<hhh", data[:6])  # AK8963 es little-endian
    if data[6] & 0x08:  # overflow
        return 0.0, 0.0, 0.0
    return mx * 0.15, my * 0.15, mz * 0.15


def init_icm20948(dev, name):
    """Inicializar ICM-20948 (banco de registros)."""
    def set_bank(bank):
        dev.write_reg(0x7F, bank)

    # Reset
    dev.write_reg(0x7F, 0x00)
    dev.write_reg(0x06, 0x01)
    time.sleep_ms(10)

    # PWR_MGMT_1 (bank 0, reg 0x06)
    dev.write_reg(0x06, 0x01)  # sleep off, auto-select clock
    time.sleep_ms(10)

    # Accel config (bank 2, reg 0x01)
    set_bank(0x20)
    dev.write_reg(0x01, 0x01)  # accel: ±4g, DLPF on
    # Gyro config (bank 2, reg 0x00)
    dev.write_reg(0x00, 0x01)  # gyro: ±250°/s, DLPF on
    set_bank(0x00)

    # ODR: accel/gyro ~225 Hz (bank 0, reg 0x10 = 0x04)
    dev.write_reg(0x10, 0x04)

    print(f"  {name}: ±4g accel, ±250°/s gyro (banked regs)")
    return True


def read_icm20948(dev, mag_dev=None):
    """Leer ICM-20948 accel+gyro."""
    dev.write_reg(0x7F, 0x00)
    data = dev.read_reg(0x2D, 12)
    ax, ay, az, gx, gy, gz = struct.unpack(">hhhhhh", data)
    ax_f = ax / 8192.0   # ±4g
    ay_f = ay / 8192.0
    az_f = az / 8192.0
    gx_f = gx / 131.0    # ±250°/s
    gy_f = gy / 131.0
    gz_f = gz / 131.0
    mx = my = mz = 0.0
    return ax_f, ay_f, az_f, gx_f, gy_f, gz_f, mx, my, mz


def init_lsm6ds(dev, name):
    """Inicializar LSM6DS3/DSO."""
    dev.write_reg(0x12, 0x44)  # CTRL3_C: BDU + auto-increment
    dev.write_reg(0x10, 0x60)  # CTRL1_XL: accel 416 Hz, ±2g, 200 Hz ODR
    dev.write_reg(0x11, 0x50)  # CTRL2_G:  gyro 416 Hz, ±250°/s
    print(f"  {name}: accel ±2g, gyro ±250°/s, 416 Hz ODR")
    return True


def read_lsm6ds(dev, mag_dev=None):
    """Leer LSM6DS3/DSO."""
    data = dev.read_reg(0x22, 12)
    gx, gy, gz, ax, ay, az = struct.unpack("<hhhhhh", data)
    ax_f = ax / 16384.0   # ±2g
    ay_f = ay / 16384.0
    az_f = az / 16384.0
    gx_f = gx / 131.0     # ±250°/s (aproximado — cheque datasheet)
    gy_f = gy / 131.0
    gz_f = gz / 131.0
    return ax_f, ay_f, az_f, gx_f, gy_f, gz_f, 0.0, 0.0, 0.0


def init_bmi160(dev, name):
    """Inicializar BMI160."""
    dev.write_reg(0x7E, 0xB6)  # soft reset
    time.sleep_ms(50)
    # Accel: ±2g, normal mode (reg 0x40 = 0x11)
    dev.write_reg(0x40, 0x11)
    # Gyro: ±250°/s, normal mode (reg 0x42 = 0x10)
    dev.write_reg(0x42, 0x10)
    # Accel ODR 200 Hz (reg 0x41 = 0x28)
    dev.write_reg(0x41, 0x28)
    # Gyro ODR 200 Hz (reg 0x43 = 0x28)
    dev.write_reg(0x43, 0x28)
    # Command register: start NMI (no op)
    print(f"  {name}: ±2g accel, ±250°/s gyro, 200 Hz")
    return True


def read_bmi160(dev, mag_dev=None):
    """Leer BMI160 accel+gyro."""
    data = dev.read_reg(0x0C, 12)
    gx, gy, gz, ax, ay, az = struct.unpack("<hhhhhh", data)
    ax_f = ax / 16384.0
    ay_f = ay / 16384.0
    az_f = az / 16384.0
    gx_f = gx / 131.0
    gy_f = gy / 131.0
    gz_f = gz / 131.0
    return ax_f, ay_f, az_f, gx_f, gy_f, gz_f, 0.0, 0.0, 0.0


def init_adxl345(dev, name):
    """Inicializar ADXL345."""
    dev.write_reg(0x2D, 0x08)  # POWER_CTL: measure on
    dev.write_reg(0x31, 0x00)  # DATA_FORMAT: ±2g, 10-bit, right-justified
    dev.write_reg(0x2C, 0x09)  # BW_RATE: 50 Hz
    print(f"  {name}: ±2g, 50 Hz")
    return True


def read_adxl345(dev, mag_dev=None):
    """Leer ADXL345 accel only (little-endian)."""
    data = dev.read_reg(0x32, 6)
    ax, ay, az = struct.unpack("<hhh", data)
    ax_f = ax / 256.0   # ±2g, 10-bit → 256 LSB/g
    ay_f = ay / 256.0
    az_f = az / 256.0
    return ax_f, ay_f, az_f, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0


# ============================================================
#  DISPATCH TABLE
# ============================================================
FAMILY_CONFIG = {
    "mpu":       (init_mpu,       read_mpu),
    "icm20948":  (init_icm20948,  read_icm20948),
    "lsm6ds":    (init_lsm6ds,    read_lsm6ds),
    "bmi160":    (init_bmi160,    read_bmi160),
    "adxl345":   (init_adxl345,   read_adxl345),
}

MAG_INITS = {
    "ak8963":  init_ak8963,
}


# ============================================================
#  MAIN
# ============================================================
def main():
    print("\n===================================")
    print("  IMU TEST — MicroPython Detector")
    print("===================================")
    print(f"  I2C{I2C_ID}: SDA=GP{SDA_PIN}, SCL=GP{SCL_PIN}, {I2C_FREQ // 1000} kHz")
    print("===================================\n")

    # 1. Inicializar I2C
    i2c = I2C(I2C_ID, scl=Pin(SCL_PIN), sda=Pin(SDA_PIN), freq=I2C_FREQ)
    time.sleep_ms(500)

    # 2. Escanear bus
    devices = scan_bus(i2c)
    if not devices:
        print("\n  ⚠  No hay dispositivos I2C conectados.")
        print("     Verifica: alimentación, pull-ups, pines GP8/GP9\n")
        while True:
            time.sleep(1)

    # 3. Detectar IMU
    print("\n[IMU] Detectando...")
    imu_list, mag_info = detect_imu(i2c, devices)

    if not imu_list:
        print("\n  ✗ IMU desconocida o no compatible.")
        print("  Mostrando direcciones I2C sin identificación:")
        for addr in devices:
            print(f"    0x{addr:02X}")
        print("\n  Prueba: si ves 0x68/0x6A/0x53, tu IMU usa registro WHO_AM_I")
        print("  diferente o necesita inicialización especial.\n")
        while True:
            time.sleep(1)

    name, addr, family = imu_list[0]
    imu_dev = I2CDevice(i2c, addr)

    # 4. Inicializar IMU
    print(f"\n[INIT] Inicializando {name}...")
    init_fn, read_fn = FAMILY_CONFIG[family]
    if not init_fn(imu_dev, name):
        print("  ✗ Error de inicialización")
        while True:
            time.sleep(1)

    # 5. Inicializar magnetómetro si existe
    mag_dev = None
    if mag_info:
        mag_name, mag_addr, mag_family = mag_info
        mag_dev = I2CDevice(i2c, mag_addr)
        if mag_family in MAG_INITS:
            if MAG_INITS[mag_family](mag_dev):
                print(f"  Magnetómetro listo")

    # 6. Bucle principal
    print("\n[STREAM] Datos en formato CSV:")
    print("t_ms,ax(g),ay(g),az(g),gx(dps),gy(dps),gz(dps),mx(uT),my(uT),mz(uT)")
    print("--------")
    t0 = time.ticks_ms()
    while True:
        t_now = time.ticks_diff(time.ticks_ms(), t0)
        try:
            ax, ay, az, gx, gy, gz, mx, my, mz = read_fn(imu_dev, mag_dev)
            print(f"{t_now},{ax:.6f},{ay:.6f},{az:.6f},"
                  f"{gx:.6f},{gy:.6f},{gz:.6f},"
                  f"{mx:.2f},{my:.2f},{mz:.2f}")
        except OSError as e:
            print(f"ERROR_LECTURA,{e}")
        time.sleep_ms(SAMPLE_RATE_MS)


# ── Arranque ────────────────────────────────────────────────
if __name__ == "__main__":
    main()
