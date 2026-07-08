#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// -----------------------------------------------------------------------------
// 引脚配置 (Pin Configuration) — 出厂默认值，实际生效值存在 NVS 里，
// 可通过 SETPIN 命令按设备修正错误焊接，无需重新烧录固件。
// -----------------------------------------------------------------------------
const int DEFAULT_LED_RED = 5;
const int DEFAULT_LED_YELLOW = 6;
const int DEFAULT_LED_GREEN = 7;

// 接线校准向导允许测试的安全 GPIO 列表（ESP32-C3 Super Mini 可用引脚，
// 排除原生 USB 占用的 18/19）。
const int SAFE_GPIO_PINS[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 21};
const int SAFE_GPIO_PIN_COUNT = 13;

// -----------------------------------------------------------------------------
// 蓝牙配置 (BLE Configuration) — 出厂默认前缀，实际广播名称存在 NVS 里，
// 首次开机直接以此前缀写入；app 改名后写回 NVS，固件更新不会覆盖。
// -----------------------------------------------------------------------------
const String BLE_NAME_PREFIX = "WG-A1";

// 基础 UUID: "wisdomgarden" 的 ASCII 十六进制编码加序号
#define SERVICE_UUID "77697364-6f6d-6761-7264-656e00000001"
#define COMMAND_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000002"
#define OTA_CONTROL_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000003"
#define OTA_DATA_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000004"

// -----------------------------------------------------------------------------
// 固件版本 (Firmware Version) — bump manually before compiling a new build
// -----------------------------------------------------------------------------
const String FIRMWARE_VERSION = "1.0.0";
#define INFO_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000005"

#endif // CONFIG_H
