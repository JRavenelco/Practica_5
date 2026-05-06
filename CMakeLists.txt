# Generated Cmake Pico project file

cmake_minimum_required(VERSION 3.13)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Initialise pico_sdk from installed location
# (note this can come from environment, CMake cache etc)

# == DO NOT EDIT THE FOLLOWING LINES for the Raspberry Pi Pico VS Code Extension to work ==
if(WIN32)
    set(USERHOME $ENV{USERPROFILE})
else()
    set(USERHOME $ENV{HOME})
endif()
set(sdkVersion 2.2.0)
set(toolchainVersion 14_2_Rel1)
set(picotoolVersion 2.2.0-a4)
set(picoVscode ${USERHOME}/.pico-sdk/cmake/pico-vscode.cmake)
if (EXISTS ${picoVscode})
    include(${picoVscode})
endif()
# ====================================================================================
set(PICO_BOARD pico_w CACHE STRING "Board type")
set(WIFI_SSID "Redmi Note 13 Pro 5G" CACHE STRING "Wi-Fi SSID")
set(WIFI_PASSWORD "robotsmek" CACHE STRING "Wi-Fi password")
set(WIFI_TCP_PORT 4242 CACHE STRING "TCP port for MATLAB acquisition")

# Pull in Raspberry Pi Pico SDK (must be before project)
include(pico_sdk_import.cmake)

project(Practica_5 C CXX ASM)

set(FREERTOS_KERNEL_PATH ${CMAKE_CURRENT_LIST_DIR}/external/FreeRTOS-Kernel CACHE PATH "Path to the FreeRTOS Kernel")
set(FREERTOS_CONFIG_FILE_DIRECTORY ${CMAKE_CURRENT_LIST_DIR} CACHE PATH "Directory containing FreeRTOSConfig.h")
include(${FREERTOS_KERNEL_PATH}/portable/ThirdParty/GCC/RP2040/FreeRTOS_Kernel_import.cmake)

# Initialise the Raspberry Pi Pico SDK
pico_sdk_init()

# Add executable. Default name is the project name, version 0.1

add_executable(Practica_5 Practica_5.c )

pico_set_program_name(Practica_5 "Practica_5")
pico_set_program_version(Practica_5 "0.1")

# Modify the below lines to enable/disable output over UART/USB
pico_enable_stdio_uart(Practica_5 0)
pico_enable_stdio_usb(Practica_5 1)

# Add the standard library to the build
target_link_libraries(Practica_5
        pico_stdlib)

# Add the standard include files to the build
target_include_directories(Practica_5 PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}
)

target_compile_definitions(Practica_5 PRIVATE
        WIFI_SSID=\"${WIFI_SSID}\"
        WIFI_PASSWORD=\"${WIFI_PASSWORD}\"
        WIFI_TCP_PORT=${WIFI_TCP_PORT}
)

# Add any user requested libraries
target_link_libraries(Practica_5 
        hardware_i2c
        pico_cyw43_arch_lwip_sys_freertos
        FreeRTOS-Kernel-Heap4
        )

pico_add_extra_outputs(Practica_5)

# ---- Test target: FreeRTOS + CYW43 + USB CDC (no Wi-Fi, no MPU) ----
add_executable(uart_test uart_test.c)
pico_set_program_name(uart_test "uart_test")
pico_set_program_version(uart_test "0.1")
pico_enable_stdio_uart(uart_test 1)
pico_enable_stdio_usb(uart_test 0)
target_include_directories(uart_test PRIVATE ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(uart_test
        pico_stdlib
        pico_cyw43_arch_lwip_sys_freertos
        FreeRTOS-Kernel-Heap4
)
pico_add_extra_outputs(uart_test)

# ---- Minimal MPU test: bare-metal I2C + USB serial (no WiFi, no FreeRTOS) ----
add_executable(mpu_test mpu_test.c)
pico_set_program_name(mpu_test "mpu_test")
pico_set_program_version(mpu_test "0.1")
pico_enable_stdio_uart(mpu_test 0)
pico_enable_stdio_usb(mpu_test 1)
target_include_directories(mpu_test PRIVATE ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(mpu_test
        pico_stdlib
        hardware_i2c
)
pico_add_extra_outputs(mpu_test)

