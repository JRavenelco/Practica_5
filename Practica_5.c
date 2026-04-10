#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include "pico/stdlib.h"
#include "FreeRTOS.h"
#include "queue.h"
#include "semphr.h"
#include "task.h"
#include "hardware/i2c.h"
#include "hardware/uart.h"
#include "pico/cyw43_arch.h"
#include "lwip/sockets.h"
#include "lwip/netif.h"
#include "lwip/ip4_addr.h"

// I2C defines
// This example will use I2C0 on GPIO8 (SDA) and GPIO9 (SCL) running at 400KHz.
// Pins can be changed, see the GPIO function select table in the datasheet for information on GPIO assignments
#define I2C_PORT i2c0
#define I2C_SDA 8
#define I2C_SCL 9

#ifndef WIFI_SSID
#define WIFI_SSID ""
#endif

#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD ""
#endif

#ifndef WIFI_TCP_PORT
#define WIFI_TCP_PORT 4242
#endif

#define CORE0_AFFINITY_MASK ( 1u << 0 )
#define CORE1_AFFINITY_MASK ( 1u << 1 )
#define SAMPLE_QUEUE_LENGTH 64
#define DIAGNOSTIC_INTERVAL_MS 5000
#define MPU_RETRY_INTERVAL_MS 2000
#define WIFI_RETRY_INTERVAL_MS 5000
#define UART_STARTUP_WINDOW_MS 5000

#define MPU9250_ADDR 0x68
#define MPU9250_REG_SMPLRT_DIV 0x19
#define MPU9250_REG_CONFIG 0x1A
#define MPU9250_REG_GYRO_CONFIG 0x1B
#define MPU9250_REG_ACCEL_CONFIG 0x1C
#define MPU9250_REG_ACCEL_CONFIG2 0x1D
#define MPU9250_REG_INT_PIN_CFG 0x37
#define MPU9250_REG_ACCEL_XOUT_H 0x3B
#define MPU9250_REG_PWR_MGMT_1 0x6B
#define MPU9250_REG_WHO_AM_I 0x75

#define AK8963_ADDR 0x0C
#define AK8963_REG_WIA 0x00
#define AK8963_REG_ST1 0x02
#define AK8963_REG_HXL 0x03
#define AK8963_REG_CNTL1 0x0A
#define AK8963_REG_CNTL2 0x0B

#define DEBUG_UART_ID uart0
#define DEBUG_UART_BAUDRATE 115200
#define DEBUG_UART_TX_PIN 0
#define DEBUG_UART_RX_PIN 1

typedef struct {
    uint32_t t_ms;
    float ax;
    float ay;
    float az;
    float gx;
    float gy;
    float gz;
    float mx;
    float my;
    float mz;
} imu_sample_t;

typedef enum {
    LED_STATUS_OFF = 0,
    LED_STATUS_WIFI_READY,
    LED_STATUS_CLIENT_CONNECTED,
    LED_STATUS_STREAMING
} led_status_t;

static volatile bool streaming_enabled = false;
static volatile bool wifi_connected = false;
static volatile bool client_connected = false;
static volatile bool imu_available = false;
static volatile uint32_t sample_rate_hz = 200;
static volatile uint32_t sample_period_ms = 5;
static volatile led_status_t led_status = LED_STATUS_OFF;
static float gyro_bias_x_dps = 0.0f;
static float gyro_bias_y_dps = 0.0f;
static float gyro_bias_z_dps = 0.0f;
static uint32_t imu_init_attempts = 0;
static uint32_t imu_read_failures = 0;
static uint32_t boot_trace_step = 0;
static QueueHandle_t sample_queue = NULL;
static SemaphoreHandle_t imu_mutex = NULL;

static void set_sample_rate(uint32_t requested_rate_hz) {
    if (requested_rate_hz < 10) {
        requested_rate_hz = 10;
    }
    if (requested_rate_hz > 500) {
        requested_rate_hz = 500;
    }
    sample_rate_hz = requested_rate_hz;
    sample_period_ms = 1000 / sample_rate_hz;
    if (sample_period_ms == 0) {
        sample_period_ms = 1;
    }
}

static void update_status_led(void) {
    if (!wifi_connected) {
        led_status = LED_STATUS_OFF;
    } else if (streaming_enabled) {
        led_status = LED_STATUS_STREAMING;
    } else if (client_connected) {
        led_status = LED_STATUS_CLIENT_CONNECTED;
    } else {
        led_status = LED_STATUS_WIFI_READY;
    }
}

static void log_system_status(const char *tag) {
    UBaseType_t queued_samples = 0;

    if (sample_queue != NULL) {
        queued_samples = uxQueueMessagesWaiting(sample_queue);
    }

    printf("[%s] wifi=%d client=%d streaming=%d imu=%d rate=%luHz queue=%lu imu_attempts=%lu imu_read_failures=%lu\n",
           tag,
           wifi_connected ? 1 : 0,
           client_connected ? 1 : 0,
           streaming_enabled ? 1 : 0,
           imu_available ? 1 : 0,
           (unsigned long)sample_rate_hz,
           (unsigned long)queued_samples,
           (unsigned long)imu_init_attempts,
           (unsigned long)imu_read_failures);
}

static void trace_boot_step(const char *stage) {
    boot_trace_step += 1;
    printf("[BOOT %02lu] %s\n",
           (unsigned long)boot_trace_step,
           stage);
}

static void trace_boot_window(void) {
    uint32_t elapsed_ms = 0;

    while (elapsed_ms < UART_STARTUP_WINDOW_MS) {
        printf("[BOOT UART] waiting %lu/%lu ms\n",
               (unsigned long)elapsed_ms,
               (unsigned long)UART_STARTUP_WINDOW_MS);
        sleep_ms(500);
        elapsed_ms += 500;
    }

    printf("[BOOT UART] startup window complete\n");
}

static void reset_sample_queue(void) {
    if (sample_queue != NULL) {
        xQueueReset(sample_queue);
    }
}

static bool enqueue_sample(const imu_sample_t *sample) {
    imu_sample_t discarded_sample;

    if (sample_queue == NULL) {
        return false;
    }

    if (xQueueSend(sample_queue, sample, 0) == pdPASS) {
        return true;
    }

    (void)xQueueReceive(sample_queue, &discarded_sample, 0);
    return xQueueSend(sample_queue, sample, 0) == pdPASS;
}

static void i2c_bus_scan(void) {
    printf("I2C bus scan on i2c0 (SDA=%d, SCL=%d):\n", I2C_SDA, I2C_SCL);
    int found = 0;
    for (uint8_t addr = 0x08; addr < 0x78; addr++) {
        uint8_t rxdata;
        int ret = i2c_read_blocking(I2C_PORT, addr, &rxdata, 1, false);
        if (ret >= 0) {
            printf("  Device found at 0x%02X\n", addr);
            found++;
        }
    }
    if (found == 0) {
        printf("  No I2C devices found! Check wiring: SDA=GPIO%d, SCL=GPIO%d, pull-ups, VCC\n",
               I2C_SDA, I2C_SCL);
    } else {
        printf("  %d device(s) found\n", found);
    }
}

static bool mpu9250_write_register(uint8_t reg, uint8_t value) {
    uint8_t buffer[2] = {reg, value};
    return i2c_write_blocking(I2C_PORT, MPU9250_ADDR, buffer, 2, false) == 2;
}

static bool mpu9250_read_registers(uint8_t reg, uint8_t *buffer, size_t length) {
    if (i2c_write_blocking(I2C_PORT, MPU9250_ADDR, &reg, 1, true) != 1) {
        return false;
    }
    return i2c_read_blocking(I2C_PORT, MPU9250_ADDR, buffer, length, false) == (int)length;
}

static bool ak8963_write_register(uint8_t reg, uint8_t value) {
    uint8_t buffer[2] = {reg, value};
    return i2c_write_blocking(I2C_PORT, AK8963_ADDR, buffer, 2, false) == 2;
}

static bool ak8963_read_registers(uint8_t reg, uint8_t *buffer, size_t length) {
    if (i2c_write_blocking(I2C_PORT, AK8963_ADDR, &reg, 1, true) != 1) {
        return false;
    }
    return i2c_read_blocking(I2C_PORT, AK8963_ADDR, buffer, length, false) == (int)length;
}

static bool ak8963_initialize(void) {
    uint8_t wia = 0;

    /* Reset */
    ak8963_write_register(AK8963_REG_CNTL2, 0x01);
    sleep_ms(100);

    /* Verify WHO_AM_I (should be 0x48) */
    if (!ak8963_read_registers(AK8963_REG_WIA, &wia, 1)) {
        printf("AK8963 read failed\n");
        return false;
    }
    if (wia != 0x48) {
        printf("AK8963 WHO_AM_I unexpected: 0x%02X\n", wia);
        return false;
    }

    /* Continuous measurement mode 2 (100 Hz), 16-bit output */
    if (!ak8963_write_register(AK8963_REG_CNTL1, 0x16)) {
        return false;
    }
    sleep_ms(10);

    printf("AK8963 magnetometer initialized\n");
    return true;
}

static bool ak8963_read_mag(float *mx, float *my, float *mz) {
    uint8_t st1 = 0;
    uint8_t raw[7]; /* HXL, HXH, HYL, HYH, HZL, HZH, ST2 */

    if (!ak8963_read_registers(AK8963_REG_ST1, &st1, 1)) {
        return false;
    }
    if (!(st1 & 0x01)) {
        return false; /* data not ready */
    }

    if (!ak8963_read_registers(AK8963_REG_HXL, raw, 7)) {
        return false;
    }

    /* Check magnetic sensor overflow (ST2 bit 3) */
    if (raw[6] & 0x08) {
        return false;
    }

    int16_t mx_raw = (int16_t)(raw[1] << 8 | raw[0]);
    int16_t my_raw = (int16_t)(raw[3] << 8 | raw[2]);
    int16_t mz_raw = (int16_t)(raw[5] << 8 | raw[4]);

    /* 16-bit mode: 0.15 µT/LSB */
    *mx = (float)mx_raw * 0.15f;
    *my = (float)my_raw * 0.15f;
    *mz = (float)mz_raw * 0.15f;

    return true;
}

static bool mpu9250_initialize(void) {
    uint8_t who_am_i = 0;

    sleep_ms(100);

    if (!mpu9250_write_register(MPU9250_REG_PWR_MGMT_1, 0x80)) {
        return false;
    }
    sleep_ms(100);

    if (!mpu9250_write_register(MPU9250_REG_PWR_MGMT_1, 0x01)) {
        return false;
    }
    if (!mpu9250_write_register(MPU9250_REG_SMPLRT_DIV, 0x04)) {
        return false;
    }
    if (!mpu9250_write_register(MPU9250_REG_CONFIG, 0x03)) {
        return false;
    }
    if (!mpu9250_write_register(MPU9250_REG_GYRO_CONFIG, 0x00)) {
        return false;
    }
    if (!mpu9250_write_register(MPU9250_REG_ACCEL_CONFIG, 0x00)) {
        return false;
    }
    if (!mpu9250_write_register(MPU9250_REG_ACCEL_CONFIG2, 0x03)) {
        return false;
    }
    if (!mpu9250_write_register(MPU9250_REG_INT_PIN_CFG, 0x02)) {
        return false;
    }
    if (!mpu9250_read_registers(MPU9250_REG_WHO_AM_I, &who_am_i, 1)) {
        return false;
    }

    if (!((who_am_i == 0x71) || (who_am_i == 0x73))) {
        return false;
    }

    /* I2C bypass enabled (INT_PIN_CFG 0x02) allows direct AK8963 access */
    if (!ak8963_initialize()) {
        printf("AK8963 init failed, continuing without magnetometer\n");
    }

    return true;
}

static bool try_initialize_mpu(void) {
    bool init_ok = false;

    ++imu_init_attempts;

    if ((imu_mutex != NULL) && (xSemaphoreTake(imu_mutex, pdMS_TO_TICKS(1000)) == pdPASS)) {
        init_ok = mpu9250_initialize();
        xSemaphoreGive(imu_mutex);
    }

    if (init_ok) {
        imu_available = true;
        imu_read_failures = 0;
        printf("MPU-9250 detected and initialized\n");
    } else {
        imu_available = false;
        printf("MPU-9250 not detected on I2C (attempt %lu)\n", (unsigned long)imu_init_attempts);
    }

    return init_ok;
}

static bool mpu9250_read_sample(imu_sample_t *sample) {
    uint8_t raw_data[14];
    int16_t ax_raw;
    int16_t ay_raw;
    int16_t az_raw;
    int16_t gx_raw;
    int16_t gy_raw;
    int16_t gz_raw;

    if (!mpu9250_read_registers(MPU9250_REG_ACCEL_XOUT_H, raw_data, sizeof(raw_data))) {
        return false;
    }

    ax_raw = (int16_t)((raw_data[0] << 8) | raw_data[1]);
    ay_raw = (int16_t)((raw_data[2] << 8) | raw_data[3]);
    az_raw = (int16_t)((raw_data[4] << 8) | raw_data[5]);
    gx_raw = (int16_t)((raw_data[8] << 8) | raw_data[9]);
    gy_raw = (int16_t)((raw_data[10] << 8) | raw_data[11]);
    gz_raw = (int16_t)((raw_data[12] << 8) | raw_data[13]);

    sample->t_ms = (uint32_t)to_ms_since_boot(get_absolute_time());
    sample->ax = (float)ax_raw / 16384.0f;
    sample->ay = (float)ay_raw / 16384.0f;
    sample->az = (float)az_raw / 16384.0f;
    sample->gx = ((float)gx_raw / 131.0f) - gyro_bias_x_dps;
    sample->gy = ((float)gy_raw / 131.0f) - gyro_bias_y_dps;
    sample->gz = ((float)gz_raw / 131.0f) - gyro_bias_z_dps;

    /* Read magnetometer; keep previous values if data not ready */
    float mx_tmp, my_tmp, mz_tmp;
    if (ak8963_read_mag(&mx_tmp, &my_tmp, &mz_tmp)) {
        sample->mx = mx_tmp;
        sample->my = my_tmp;
        sample->mz = mz_tmp;
    } else {
        sample->mx = 0.0f;
        sample->my = 0.0f;
        sample->mz = 0.0f;
    }

    return true;
}

static bool mpu9250_calibrate_gyro_bias(void) {
    const uint32_t samples_to_average = 200;
    float sum_x = 0.0f;
    float sum_y = 0.0f;
    float sum_z = 0.0f;
    imu_sample_t sample;

    if (!imu_available) {
        return false;
    }

    if ((imu_mutex != NULL) && (xSemaphoreTake(imu_mutex, pdMS_TO_TICKS(2000)) != pdPASS)) {
        return false;
    }

    for (uint32_t k = 0; k < samples_to_average; ++k) {
        if (!mpu9250_read_sample(&sample)) {
            if (imu_mutex != NULL) {
                xSemaphoreGive(imu_mutex);
            }
            return false;
        }
        sum_x += sample.gx;
        sum_y += sample.gy;
        sum_z += sample.gz;
        sleep_ms(5);
    }

    gyro_bias_x_dps = sum_x / (float)samples_to_average;
    gyro_bias_y_dps = sum_y / (float)samples_to_average;
    gyro_bias_z_dps = sum_z / (float)samples_to_average;

    if (imu_mutex != NULL) {
        xSemaphoreGive(imu_mutex);
    }

    return true;
}

static bool wifi_sta_mode_enabled = false;

static bool wifi_connect_station(void) {
    if (strlen(WIFI_SSID) == 0) {
        printf("Configure WIFI_SSID in CMake before running.\n");
        return false;
    }

    if (!wifi_sta_mode_enabled) {
        cyw43_arch_enable_sta_mode();
        wifi_sta_mode_enabled = true;
        printf("STA mode enabled\n");
    }

    /* WPA2_AES_PSK for Windows mobile hotspot */
    int auth_type = strlen(WIFI_PASSWORD) > 0
                    ? CYW43_AUTH_WPA2_AES_PSK
                    : CYW43_AUTH_OPEN;

    printf("Connecting to Wi-Fi SSID '%s' (auth=%d, timeout=30s)...\n",
           WIFI_SSID, auth_type);
    int rc = cyw43_arch_wifi_connect_timeout_ms(
                WIFI_SSID, WIFI_PASSWORD, auth_type, 30000);
    if (rc != 0) {
        printf("Wi-Fi connection failed (rc=%d).\n", rc);
        return false;
    }

    if (netif_default != NULL) {
        printf("Wi-Fi connected! IP: %s\n", ip4addr_ntoa(netif_ip4_addr(netif_default)));
    } else {
        printf("Wi-Fi connected, IP not available yet.\n");
    }

    return true;
}

static int tcp_server_open(uint16_t port) {
    int server_fd;
    int enable = 1;
    struct sockaddr_in server_address;

    server_fd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        return -1;
    }

    lwip_setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &enable, sizeof(enable));

    memset(&server_address, 0, sizeof(server_address));
    server_address.sin_family = AF_INET;
    server_address.sin_port = PP_HTONS(port);
    server_address.sin_addr.s_addr = PP_HTONL(INADDR_ANY);

    if (lwip_bind(server_fd, (struct sockaddr *)&server_address, sizeof(server_address)) < 0) {
        lwip_close(server_fd);
        return -1;
    }

    if (lwip_listen(server_fd, 1) < 0) {
        lwip_close(server_fd);
        return -1;
    }

    return server_fd;
}

static bool tcp_send_text(int client_fd, const char *text) {
    size_t remaining = strlen(text);
    const char *cursor = text;

    while (remaining > 0) {
        int sent = lwip_send(client_fd, cursor, remaining, 0);
        if (sent <= 0) {
            return false;
        }
        cursor += sent;
        remaining -= (size_t)sent;
    }

    return true;
}

static bool process_command(int client_fd, const char *line) {
    unsigned long requested_rate = 0;

    if (strcmp(line, "START") == 0) {
        streaming_enabled = true;
        reset_sample_queue();
        update_status_led();
        return tcp_send_text(client_fd, "OK START\n");
    }

    if (strcmp(line, "STOP") == 0) {
        streaming_enabled = false;
        reset_sample_queue();
        update_status_led();
        return tcp_send_text(client_fd, "OK STOP\n");
    }

    if (strcmp(line, "PING") == 0) {
        return tcp_send_text(client_fd, "PONG\n");
    }

    if (strcmp(line, "BIAS") == 0) {
        if (!imu_available) {
            return tcp_send_text(client_fd, "ERR BIAS\n");
        }
        if (mpu9250_calibrate_gyro_bias()) {
            return tcp_send_text(client_fd, "OK BIAS\n");
        }
        return tcp_send_text(client_fd, "ERR BIAS\n");
    }

    if (sscanf(line, "RATE %lu", &requested_rate) == 1) {
        set_sample_rate((uint32_t)requested_rate);
        char response[32];
        snprintf(response, sizeof(response), "OK RATE %lu\n", (unsigned long)sample_rate_hz);
        return tcp_send_text(client_fd, response);
    }

    return tcp_send_text(client_fd, "ERR CMD\n");
}

static void handle_client_session(int client_fd) {
    char recv_buffer[128];
    char line_buffer[128];
    imu_sample_t sample;
    size_t line_length = 0;
    bool session_alive = true;
    int nodelay = 1;

    lwip_setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

    client_connected = true;
    streaming_enabled = false;
    reset_sample_queue();
    update_status_led();
    tcp_send_text(client_fd, "OK READY\n");

    while (session_alive) {
        fd_set read_fds;
        struct timeval timeout;
        int select_result;
        bool have_sample = false;

        FD_ZERO(&read_fds);
        FD_SET(client_fd, &read_fds);
        timeout.tv_sec = 0;
        timeout.tv_usec = 2000;
        select_result = lwip_select(client_fd + 1, &read_fds, NULL, NULL, &timeout);

        if (select_result < 0) {
            break;
        }

        if (select_result > 0 && FD_ISSET(client_fd, &read_fds)) {
            int bytes_received = lwip_recv(client_fd, recv_buffer, sizeof(recv_buffer), 0);
            if (bytes_received <= 0) {
                break;
            }

            for (int i = 0; i < bytes_received; ++i) {
                char c = recv_buffer[i];
                if (c == '\r') {
                    continue;
                }
                if (c == '\n') {
                    line_buffer[line_length] = '\0';
                    if (line_length > 0) {
                        session_alive = process_command(client_fd, line_buffer);
                    }
                    line_length = 0;
                    if (!session_alive) {
                        break;
                    }
                } else if (line_length < (sizeof(line_buffer) - 1)) {
                    line_buffer[line_length++] = c;
                }
            }
        }

        if (streaming_enabled) {
            char csv_line[256];

            while ((sample_queue != NULL) && (xQueueReceive(sample_queue, &sample, 0) == pdPASS)) {
                have_sample = true;
            }

            if (have_sample) {
                snprintf(csv_line,
                         sizeof(csv_line),
                         "%lu,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                         (unsigned long)sample.t_ms,
                         sample.ax,
                         sample.ay,
                         sample.az,
                         sample.gx,
                         sample.gy,
                         sample.gz,
                         sample.mx,
                         sample.my,
                         sample.mz);

                if (!tcp_send_text(client_fd, csv_line)) {
                    break;
                }
            } else if (!imu_available) {
                /* Sin IMU: enviar timestamp con ceros para verificar comunicación */
                uint32_t now = (uint32_t)to_ms_since_boot(get_absolute_time());
                snprintf(csv_line,
                         sizeof(csv_line),
                         "%lu,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000\n",
                         (unsigned long)now);
                if (!tcp_send_text(client_fd, csv_line)) {
                    break;
                }
                vTaskDelay(pdMS_TO_TICKS(1000 / sample_rate_hz));
            }
        }
    }

    streaming_enabled = false;
    client_connected = false;
    reset_sample_queue();
    update_status_led();
    lwip_close(client_fd);
}

static void mpu_sampling_task(void *parameter)
{
    (void)parameter;
    TickType_t last_wake = xTaskGetTickCount();
    TickType_t last_retry = xTaskGetTickCount();
    imu_sample_t sample;

    while (true) {
        uint32_t local_period_ms = sample_period_ms;

        if (local_period_ms == 0) {
            local_period_ms = 1;
        }

        if (!imu_available) {
            TickType_t now = xTaskGetTickCount();

            if ((now - last_retry) >= pdMS_TO_TICKS(MPU_RETRY_INTERVAL_MS)) {
                last_retry = now;
                printf("Retrying MPU-9250 detection...\n");
                (void)try_initialize_mpu();
                log_system_status("mpu_retry");
            }

            vTaskDelay(pdMS_TO_TICKS(200));
            continue;
        }

        if (streaming_enabled && client_connected) {
            if ((imu_mutex != NULL) && (xSemaphoreTake(imu_mutex, pdMS_TO_TICKS(local_period_ms)) == pdPASS)) {
                bool read_ok = mpu9250_read_sample(&sample);
                xSemaphoreGive(imu_mutex);

                if (read_ok) {
                    imu_read_failures = 0;
                    (void)enqueue_sample(&sample);
                } else {
                    ++imu_read_failures;
                    printf("MPU-9250 sample read failed (%lu)\n", (unsigned long)imu_read_failures);
                    if (imu_read_failures >= 5) {
                        imu_available = false;
                        printf("MPU-9250 marked offline after repeated read failures\n");
                        log_system_status("mpu_offline");
                    }
                }
            }
        }

        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(local_period_ms));
    }
}

static void tcp_server_task(void *parameter)
{
    int server_fd;

    (void)parameter;

    server_fd = tcp_server_open((uint16_t)WIFI_TCP_PORT);
    if (server_fd < 0) {
        printf("TCP server init failed on port %d\n", WIFI_TCP_PORT);
        wifi_connected = false;
        update_status_led();
        vTaskDelete(NULL);
    }

    printf("TCP server listening on port %d\n", WIFI_TCP_PORT);

    while (true) {
        struct sockaddr_in client_address;
        socklen_t client_length = sizeof(client_address);
        int client_fd = lwip_accept(server_fd, (struct sockaddr *)&client_address, &client_length);

        if (client_fd >= 0) {
            printf("MATLAB client connected\n");
            handle_client_session(client_fd);
            printf("MATLAB client disconnected\n");
        } else {
            vTaskDelay(pdMS_TO_TICKS(50));
        }
    }
}

static void led_status_task(void *parameter)
{
    bool led_on = false;

    (void)parameter;

    while (true) {
        led_status_t current_status = led_status;

        switch (current_status) {
            case LED_STATUS_OFF:
                led_on = false;
                cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 0);
                vTaskDelay(pdMS_TO_TICKS(200));
                break;

            case LED_STATUS_WIFI_READY:
                led_on = !led_on;
                cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, led_on ? 1 : 0);
                vTaskDelay(pdMS_TO_TICKS(700));
                break;

            case LED_STATUS_CLIENT_CONNECTED:
                led_on = true;
                cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 1);
                vTaskDelay(pdMS_TO_TICKS(200));
                break;

            case LED_STATUS_STREAMING:
                led_on = !led_on;
                cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, led_on ? 1 : 0);
                vTaskDelay(pdMS_TO_TICKS(120));
                break;

            default:
                led_on = false;
                cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 0);
                vTaskDelay(pdMS_TO_TICKS(200));
                break;
        }
    }
}

static void diagnostics_task(void *parameter)
{
    (void)parameter;

    while (true) {
        log_system_status("heartbeat");
        vTaskDelay(pdMS_TO_TICKS(DIAGNOSTIC_INTERVAL_MS));
    }
}

static void setup_debug_uart(void) {
    /* stdio_uart is OFF — output goes through USB CDC only.
       GP0/GP1 are free (not used by stdio). */
    stdio_init_all();
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

static void app_main_task(void *parameter)
{
    (void)parameter;

    /* stdio ya inicializado en main() */

    printf("Practica_5 boot (FreeRTOS task)\n");
    printf("Configured Wi-Fi SSID: '%s'\n", WIFI_SSID);
    printf("Configured TCP port: %d\n", WIFI_TCP_PORT);
    printf("Initial sample rate: %lu Hz\n", (unsigned long)sample_rate_hz);
    trace_boot_step("app_main_task started");
    trace_boot_step("starting CYW43 init");

    if (cyw43_arch_init_with_country(CYW43_COUNTRY_MEXICO)) {
        trace_boot_step("CYW43 init failed");
        printf("Wi-Fi init failed\n");
        vTaskDelete(NULL);
    }
    trace_boot_step("CYW43 init complete");

    trace_boot_step("starting I2C init");
    i2c_init(I2C_PORT, 400 * 1000);

    gpio_set_function(I2C_SDA, GPIO_FUNC_I2C);
    gpio_set_function(I2C_SCL, GPIO_FUNC_I2C);
    gpio_pull_up(I2C_SDA);
    gpio_pull_up(I2C_SCL);
    trace_boot_step("I2C init complete");

    i2c_bus_scan();

    set_sample_rate(sample_rate_hz);
    wifi_connected = false;
    client_connected = false;
    update_status_led();
    trace_boot_step("sample rate and LED state initialized");

    imu_mutex = xSemaphoreCreateMutex();
    sample_queue = xQueueCreate(SAMPLE_QUEUE_LENGTH, sizeof(imu_sample_t));
    if ((imu_mutex == NULL) || (sample_queue == NULL)) {
        trace_boot_step("FreeRTOS queue/mutex init failed");
        printf("FreeRTOS queue/mutex init failed\n");
        cyw43_arch_deinit();
        vTaskDelete(NULL);
    }
    trace_boot_step("FreeRTOS queue/mutex init complete");

    trace_boot_step("starting initial MPU probe");
    if (try_initialize_mpu()) {
        trace_boot_step("initial MPU probe succeeded");
    } else {
        trace_boot_step("initial MPU probe failed, continuing without MPU");
    }

    trace_boot_step("starting Wi-Fi connection loop");
    {
        int wifi_attempts = 0;
        const int max_wifi_attempts = 10;
        bool wifi_ok = false;
        while (!wifi_connect_station()) {
            wifi_attempts++;
            wifi_connected = false;
            update_status_led();
            log_system_status("wifi_retry");
            printf("Wi-Fi attempt %d/%d failed. Retrying in %d ms\n",
                   wifi_attempts, max_wifi_attempts, WIFI_RETRY_INTERVAL_MS);
            if (wifi_attempts >= max_wifi_attempts) {
                printf("Wi-Fi gave up after %d attempts. Continuing without Wi-Fi.\n",
                       max_wifi_attempts);
                break;
            }
            vTaskDelay(pdMS_TO_TICKS(WIFI_RETRY_INTERVAL_MS));
        }
        wifi_ok = (wifi_attempts < max_wifi_attempts) || wifi_connect_station();
        wifi_connected = wifi_ok;
    }

    update_status_led();
    if (wifi_connected) {
        log_system_status("wifi_connected");
        trace_boot_step("Wi-Fi connected");
    } else {
        log_system_status("wifi_failed");
        trace_boot_step("Wi-Fi NOT connected, continuing");
    }

    if (xTaskCreateAffinitySet(mpu_sampling_task,
                               "mpu_task",
                               2048,
                               NULL,
                               tskIDLE_PRIORITY + 3,
                               CORE1_AFFINITY_MASK,
                               NULL) != pdPASS) {
        trace_boot_step("MPU task create failed");
        printf("MPU task create failed\n");
        cyw43_arch_deinit();
        vTaskDelete(NULL);
    }
    trace_boot_step("MPU task created");

    if (xTaskCreateAffinitySet(led_status_task,
                               "led_task",
                               1024,
                               NULL,
                               tskIDLE_PRIORITY + 1,
                               CORE0_AFFINITY_MASK,
                               NULL) != pdPASS) {
        trace_boot_step("LED task create failed");
        printf("LED task create failed\n");
        cyw43_arch_deinit();
        vTaskDelete(NULL);
    }
    trace_boot_step("LED task created");

    if (xTaskCreateAffinitySet(diagnostics_task,
                               "diag_task",
                               1536,
                               NULL,
                               tskIDLE_PRIORITY + 1,
                               CORE0_AFFINITY_MASK,
                               NULL) != pdPASS) {
        trace_boot_step("Diagnostics task create failed");
        printf("Diagnostics task create failed\n");
        cyw43_arch_deinit();
        vTaskDelete(NULL);
    }
    trace_boot_step("Diagnostics task created");

    if (xTaskCreateAffinitySet(tcp_server_task,
                               "tcp_task",
                               4096,
                               NULL,
                               tskIDLE_PRIORITY + 2,
                               CORE0_AFFINITY_MASK,
                               NULL) != pdPASS) {
        trace_boot_step("TCP task create failed");
        printf("TCP task create failed\n");
        cyw43_arch_deinit();
        vTaskDelete(NULL);
    }
    trace_boot_step("TCP task created");
    trace_boot_step("app_main_task completed setup");

    vTaskDelete(NULL);
}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask;
    (void)pcTaskName;
    while (true) {
        tight_loop_contents();
    }
}

void vApplicationMallocFailedHook(void)
{
    while (true) {
        tight_loop_contents();
    }
}

int main()
{
    stdio_init_all();
    sleep_ms(500);
    printf("\n=== Practica_5 boot ===\n");

    xTaskCreateAffinitySet(app_main_task,
                           "app_main",
                           3072,
                           NULL,
                           tskIDLE_PRIORITY + 4,
                           CORE0_AFFINITY_MASK,
                           NULL);
    vTaskStartScheduler();

    while (true) {
        tight_loop_contents();
    }
}
