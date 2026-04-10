/**
 * uart_test.c  — Wi-Fi scan + connect test
 */

#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"
#include "lwip/netif.h"
#include "FreeRTOS.h"
#include "task.h"

static int scan_result_count = 0;

static int scan_callback(void *env, const cyw43_ev_scan_result_t *result) {
    if (result) {
        scan_result_count++;
        printf("  [%d] SSID='%s' RSSI=%d ch=%d auth=%d\n",
               scan_result_count, result->ssid, result->rssi,
               result->channel, result->auth_mode);
    }
    return 0;
}

static void test_task(void *param)
{
    (void)param;

    printf("[1] Task running on core %u\n", get_core_num());
    printf("[2] Free heap: %u bytes\n", (unsigned)xPortGetFreeHeapSize());

    printf("[3] Calling cyw43_arch_init()...\n");
    int rc = cyw43_arch_init();
    if (rc) {
        printf("[3] CYW43 init FAILED rc=%d\n", rc);
        while (true) { vTaskDelay(pdMS_TO_TICKS(1000)); }
    }
    printf("[3] CYW43 init OK\n");

    /* LED ON */
    cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, 1);

    /* Enable STA mode */
    cyw43_arch_enable_sta_mode();
    printf("[4] STA mode enabled\n");

    /* Wi-Fi Scan */
    printf("[5] Starting Wi-Fi scan...\n");
    cyw43_wifi_scan_options_t scan_opts = {0};
    rc = cyw43_wifi_scan(&cyw43_state, &scan_opts, NULL, scan_callback);
    if (rc != 0) {
        printf("[5] Scan start failed rc=%d\n", rc);
    } else {
        /* Wait for scan to complete (10 sec max) */
        for (int i = 0; i < 20; i++) {
            vTaskDelay(pdMS_TO_TICKS(500));
            if (!cyw43_wifi_scan_active(&cyw43_state)) break;
        }
        printf("[5] Scan done. Found %d networks.\n", scan_result_count);
    }

    /* Try connect */
    printf("[6] Connecting to 'Robot' (WPA2_MIXED_PSK, 30s)...\n");
    rc = cyw43_arch_wifi_connect_timeout_ms("Robot", "Rave2310",
            CYW43_AUTH_WPA2_MIXED_PSK, 30000);
    if (rc == 0) {
        printf("[6] Wi-Fi CONNECTED!\n");
        if (netif_default) {
            printf("[6] IP: %s\n", ip4addr_ntoa(netif_ip4_addr(netif_default)));
        }
    } else {
        printf("[6] Wi-Fi FAILED rc=%d\n", rc);
        /* Try again with WPA2_AES_PSK */
        printf("[7] Retry with WPA2_AES_PSK (30s)...\n");
        rc = cyw43_arch_wifi_connect_timeout_ms("Robot", "Rave2310",
                CYW43_AUTH_WPA2_AES_PSK, 30000);
        if (rc == 0) {
            printf("[7] Wi-Fi CONNECTED with AES!\n");
        } else {
            printf("[7] Wi-Fi FAILED again rc=%d\n", rc);
        }
    }

    uint32_t counter = 0;
    while (true) {
        bool led_on = (counter & 1);
        cyw43_arch_gpio_put(CYW43_WL_GPIO_LED_PIN, led_on);
        printf("tick %lu LED=%s heap=%u\n", (unsigned long)counter,
               led_on ? "ON" : "OFF", (unsigned)xPortGetFreeHeapSize());
        counter++;
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask;
    printf("!!! STACK OVERFLOW in task: %s\n", pcTaskName);
    while (true) { __asm volatile("nop"); }
}

void vApplicationMallocFailedHook(void)
{
    printf("!!! MALLOC FAILED heap=%u\n", (unsigned)xPortGetFreeHeapSize());
    while (true) { __asm volatile("nop"); }
}

int main(void)
{
    stdio_init_all();
    /* 5s delay so serial monitor can connect before any output */
    for (int i = 5; i > 0; i--) {
        sleep_ms(1000);
    }
    printf("\n=== WiFi scan+connect test (heap=%uKB) ===\n",
           (unsigned)(configTOTAL_HEAP_SIZE / 1024));

    xTaskCreate(test_task, "test", 4096, NULL, 1, NULL);
    printf("Starting FreeRTOS scheduler...\n");
    vTaskStartScheduler();

    printf("!!! Scheduler exited\n");
    while (true) { __asm volatile("nop"); }
    return 0;
}
