/**
 * mpu_test.c — Minimal MPU-6050/9250 I2C test with USB serial output.
 *
 * No WiFi, no FreeRTOS. Reads accelerometer + gyroscope at ~50 Hz
 * and prints CSV over USB CDC so you can use the VS Code Serial Monitor.
 *
 * Wiring: GP8 = SDA, GP9 = SCL (400 kHz), 3V3 → VCC, GND → GND
 */

#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"
#include "hardware/i2c.h"

/* ---------- MPU config ---------- */
#define MPU_I2C       i2c0
#define MPU_SDA_PIN   8
#define MPU_SCL_PIN   9
#define MPU_ADDR      0x68
#define MPU_FREQ_KHZ  400

/* MPU registers */
#define REG_WHO_AM_I    0x75
#define REG_PWR_MGMT_1  0x6B
#define REG_SMPLRT_DIV  0x19
#define REG_CONFIG       0x1A
#define REG_GYRO_CONFIG  0x1B
#define REG_ACCEL_CONFIG 0x1C
#define REG_INT_PIN_CFG  0x37
#define REG_ACCEL_XOUT_H 0x3B

#define AK8963_ADDR      0x0C
#define AK8963_REG_WIA   0x00
#define AK8963_REG_ST1   0x02
#define AK8963_REG_HXL   0x03
#define AK8963_REG_CNTL1 0x0A
#define AK8963_REG_CNTL2 0x0B

/* ---------- helpers ---------- */

static bool mpu_write_reg(uint8_t reg, uint8_t val) {
    uint8_t buf[2] = { reg, val };
    return i2c_write_blocking(MPU_I2C, MPU_ADDR, buf, 2, false) == 2;
}

static bool mpu_read_reg(uint8_t reg, uint8_t *val) {
    if (i2c_write_blocking(MPU_I2C, MPU_ADDR, &reg, 1, true) != 1)
        return false;
    return i2c_read_blocking(MPU_I2C, MPU_ADDR, val, 1, false) == 1;
}

static bool mpu_read_bytes(uint8_t reg, uint8_t *buf, size_t len) {
    if (i2c_write_blocking(MPU_I2C, MPU_ADDR, &reg, 1, true) != 1)
        return false;
    return i2c_read_blocking(MPU_I2C, MPU_ADDR, buf, len, false) == (int)len;
}

static bool ak8963_write_reg(uint8_t reg, uint8_t val) {
    uint8_t buf[2] = { reg, val };
    return i2c_write_blocking(MPU_I2C, AK8963_ADDR, buf, 2, false) == 2;
}

static bool ak8963_read_bytes(uint8_t reg, uint8_t *buf, size_t len) {
    if (i2c_write_blocking(MPU_I2C, AK8963_ADDR, &reg, 1, true) != 1)
        return false;
    return i2c_read_blocking(MPU_I2C, AK8963_ADDR, buf, len, false) == (int)len;
}

static int16_t combine(uint8_t h, uint8_t l) {
    return (int16_t)((h << 8) | l);
}

static bool ak8963_initialize(void) {
    uint8_t who = 0;

    if (!ak8963_write_reg(AK8963_REG_CNTL2, 0x01))
        return false;
    sleep_ms(100);

    if (!ak8963_read_bytes(AK8963_REG_WIA, &who, 1))
        return false;
    if (who != 0x48)
        return false;

    if (!ak8963_write_reg(AK8963_REG_CNTL1, 0x16))
        return false;
    sleep_ms(10);
    return true;
}

static bool ak8963_read_mag(float *mx, float *my, float *mz) {
    uint8_t st1 = 0;
    uint8_t raw[7];

    if (!ak8963_read_bytes(AK8963_REG_ST1, &st1, 1))
        return false;
    if ((st1 & 0x01) == 0)
        return false;

    if (!ak8963_read_bytes(AK8963_REG_HXL, raw, sizeof(raw)))
        return false;
    if (raw[6] & 0x08)
        return false;

    *mx = (float)combine(raw[1], raw[0]) * 0.15f;
    *my = (float)combine(raw[3], raw[2]) * 0.15f;
    *mz = (float)combine(raw[5], raw[4]) * 0.15f;
    return true;
}

/* ---------- main ---------- */

int main(void) {
    stdio_init_all();
    bool mag_available = false;

    /* Small delay to let USB CDC enumerate */
    sleep_ms(2000);

    printf("\n=============================\n");
    printf("  MPU Test — USB Serial\n");
    printf("=============================\n\n");

    /* I2C init */
    i2c_init(MPU_I2C, MPU_FREQ_KHZ * 1000);
    gpio_set_function(MPU_SDA_PIN, GPIO_FUNC_I2C);
    gpio_set_function(MPU_SCL_PIN, GPIO_FUNC_I2C);
    gpio_pull_up(MPU_SDA_PIN);
    gpio_pull_up(MPU_SCL_PIN);

    printf("[I2C] Initialized at %d kHz (SDA=GP%d, SCL=GP%d)\n",
           MPU_FREQ_KHZ, MPU_SDA_PIN, MPU_SCL_PIN);

    /* I2C bus scan */
    printf("[I2C] Scanning bus...\n");
    int found = 0;
    for (uint8_t addr = 0x08; addr < 0x78; addr++) {
        uint8_t dummy;
        int ret = i2c_read_blocking(MPU_I2C, addr, &dummy, 1, false);
        if (ret >= 0) {
            printf("  Found device at 0x%02X\n", addr);
            found++;
        }
    }
    if (found == 0) {
        printf("  No I2C devices found! Check wiring.\n");
        printf("  Halting.\n");
        while (true) {
            tight_loop_contents();
        }
    }

    /* WHO_AM_I check */
    uint8_t who = 0;
    if (!mpu_read_reg(REG_WHO_AM_I, &who)) {
        printf("[MPU] Failed to read WHO_AM_I\n");
        while (true) tight_loop_contents();
    }
    printf("[MPU] WHO_AM_I = 0x%02X", who);
    if (who == 0x71 || who == 0x73)
        printf(" (MPU-9250)\n");
    else if (who == 0x68)
        printf(" (MPU-6050)\n");
    else
        printf(" (unknown, continuing anyway)\n");

    /* Wake up + configure */
    mpu_write_reg(REG_PWR_MGMT_1, 0x01);  /* PLL with X-axis gyro ref */
    sleep_ms(100);
    mpu_write_reg(REG_SMPLRT_DIV, 0x04);  /* 200 Hz sample rate */
    mpu_write_reg(REG_CONFIG, 0x03);       /* DLPF ~44 Hz */
    mpu_write_reg(REG_GYRO_CONFIG, 0x08);  /* ±500 °/s */
    mpu_write_reg(REG_ACCEL_CONFIG, 0x00); /* ±2 g */
    mpu_write_reg(REG_INT_PIN_CFG, 0x02);  /* Enable I2C bypass to AK8963 */

    if ((who == 0x71 || who == 0x73) && ak8963_initialize()) {
        mag_available = true;
        printf("[AK8963] Magnetometer initialized\n");
    } else {
        printf("[AK8963] Magnetometer not available, sending zeros for mx,my,mz\n");
    }

    printf("[MPU] Configured: ±2g accel, ±500°/s gyro, 200 Hz\n\n");
    printf("t_ms,ax,ay,az,gx,gy,gz,mx,my,mz\n");

    /* Conversion factors */
    const float accel_scale = 16384.0f; /* LSB/g for ±2g */
    const float gyro_scale  = 65.5f;    /* LSB/(°/s) for ±500°/s */

    absolute_time_t t_start = get_absolute_time();

    while (true) {
        uint8_t raw[14];
        if (mpu_read_bytes(REG_ACCEL_XOUT_H, raw, 14)) {
            int64_t t_ms = absolute_time_diff_us(t_start, get_absolute_time()) / 1000;

            float ax = combine(raw[0],  raw[1])  / accel_scale;
            float ay = combine(raw[2],  raw[3])  / accel_scale;
            float az = combine(raw[4],  raw[5])  / accel_scale;
            /* raw[6..7] = temperature, skip */
            float gx = combine(raw[8],  raw[9])  / gyro_scale;
            float gy = combine(raw[10], raw[11]) / gyro_scale;
            float gz = combine(raw[12], raw[13]) / gyro_scale;
            float mx = 0.0f;
            float my = 0.0f;
            float mz = 0.0f;

            if (mag_available) {
                (void)ak8963_read_mag(&mx, &my, &mz);
            }

            printf("%lld,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                   t_ms, ax, ay, az, gx, gy, gz, mx, my, mz);
        } else {
            printf("READ_ERROR\n");
        }

        sleep_ms(20); /* ~50 Hz */
    }

    return 0;
}
