#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include "rp2040_config.h"

#ifndef portTICK_RATE_MS
#define portTICK_RATE_MS portTICK_PERIOD_MS
#endif

#define configUSE_PREEMPTION 1
#define configUSE_TIME_SLICING 1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configUSE_TICKLESS_IDLE 0
#define configCPU_CLOCK_HZ 125000000UL
#define configTICK_RATE_HZ 1000
#define configMAX_PRIORITIES 8
#define configMINIMAL_STACK_SIZE 256
#define configMAX_TASK_NAME_LEN 16
#define configUSE_16_BIT_TICKS 0
#define configIDLE_SHOULD_YIELD 1
#define configUSE_TASK_NOTIFICATIONS 1
#define configTASK_NOTIFICATION_ARRAY_ENTRIES 1
#define configQUEUE_REGISTRY_SIZE 0
#define configENABLE_BACKWARD_COMPATIBILITY 0
#define configNUM_THREAD_LOCAL_STORAGE_POINTERS 0
#define configSTACK_DEPTH_TYPE uint32_t
#define configMESSAGE_BUFFER_LENGTH_TYPE size_t

#define configUSE_TIMERS 1
#define configTIMER_TASK_PRIORITY ( configMAX_PRIORITIES - 1 )
#define configTIMER_QUEUE_LENGTH 10
#define configTIMER_TASK_STACK_DEPTH configMINIMAL_STACK_SIZE

#define configUSE_MUTEXES 1
#define configUSE_RECURSIVE_MUTEXES 1
#define configUSE_COUNTING_SEMAPHORES 1
#define configUSE_QUEUE_SETS 0
#define configUSE_APPLICATION_TASK_TAG 0
#define configUSE_NEWLIB_REENTRANT 0
#define configUSE_STREAM_BUFFERS 1
#define configUSE_EVENT_GROUPS 1

#define configSUPPORT_STATIC_ALLOCATION 1
#define configKERNEL_PROVIDED_STATIC_MEMORY 1
#define configSUPPORT_DYNAMIC_ALLOCATION 1
#define configTOTAL_HEAP_SIZE (64 * 1024)
#define configAPPLICATION_ALLOCATED_HEAP 0

#define configCHECK_FOR_STACK_OVERFLOW 2
#define configUSE_MALLOC_FAILED_HOOK 1
#define configUSE_IDLE_HOOK 0
#define configUSE_TICK_HOOK 0
#define configUSE_DAEMON_TASK_STARTUP_HOOK 0

#define configRUN_TIME_COUNTER_TYPE uint32_t
#define configGENERATE_RUN_TIME_STATS 0
#define configUSE_TRACE_FACILITY 0
#define configUSE_STATS_FORMATTING_FUNCTIONS 0

#define configUSE_CO_ROUTINES 0
#define configMAX_CO_ROUTINE_PRIORITIES 1

#define configUSE_CORE_AFFINITY 1
#define configNUMBER_OF_CORES 2
#define configTICK_CORE 0
#define configRUN_MULTIPLE_PRIORITIES 1
#define configTASK_DEFAULT_CORE_AFFINITY tskNO_AFFINITY
#define configUSE_TASK_PREEMPTION_DISABLE 0
#define configUSE_PASSIVE_IDLE_HOOK 0
#define configTIMER_SERVICE_TASK_CORE_AFFINITY tskNO_AFFINITY

#define configASSERT(x) do { if(!(x)) { printf("ASSERT FAIL: %s @ %s:%d\n", #x, __FILE__, __LINE__); for(;;){} } } while(0)

#define INCLUDE_vTaskPrioritySet 1
#define INCLUDE_uxTaskPriorityGet 1
#define INCLUDE_vTaskDelete 1
#define INCLUDE_vTaskSuspend 1
#define INCLUDE_xResumeFromISR 1
#define INCLUDE_vTaskDelay 1
#define INCLUDE_xTaskDelayUntil 1
#define INCLUDE_xTaskGetSchedulerState 1
#define INCLUDE_xTaskGetCurrentTaskHandle 1
#define INCLUDE_uxTaskGetStackHighWaterMark 1
#define INCLUDE_eTaskGetState 1
#define INCLUDE_xTimerPendFunctionCall 1
#define INCLUDE_xSemaphoreGetMutexHolder 1

#endif
