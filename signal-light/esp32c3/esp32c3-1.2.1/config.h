#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// -----------------------------------------------------------------------------
// 引脚配置 (Pin Configuration) — 出厂默认值，实际生效值存在 NVS 里，
// 可通过 SETPIN 命令按设备修正错误焊接，无需重新烧录固件。
// -----------------------------------------------------------------------------
const int DEFAULT_LED_GREEN = 6;
const int DEFAULT_LED_YELLOW = 7;
const int DEFAULT_LED_RED = 10;

// 物理开关机按键引脚（无自锁开关，接 GND，内部上拉）。固定接线，不经 NVS
// 重新分配；旧硬件上该引脚悬空未接，不影响其正常运行。
const int BUTTON_PIN = 0;

// 接线校准向导允许测试的安全 GPIO 列表（ESP32-C3 Super Mini 可用引脚，
// 排除原生 USB 占用的 18/19、被按键占用的 0，以及不用于功能的 2/8/9）。
// 数量用 sizeof 自动计算，避免再次出现数组和数量对不上导致的越界读取。
const int SAFE_GPIO_PINS[] = {1, 3, 4, 5, 6, 7, 10, 20, 21};
const int SAFE_GPIO_PIN_COUNT = sizeof(SAFE_GPIO_PINS) / sizeof(SAFE_GPIO_PINS[0]);

// -----------------------------------------------------------------------------
// 蓝牙配置 (BLE Configuration) — 出厂默认前缀，实际广播名称存在 NVS 里，
// 首次开机直接以此前缀写入；app 改名后写回 NVS，固件更新不会覆盖。
// -----------------------------------------------------------------------------
const String BLE_NAME_PREFIX = "WG-PLUS";

// 基础 UUID: "wisdomgarden" 的 ASCII 十六进制编码加序号
#define SERVICE_UUID "77697364-6f6d-6761-7264-656e00000001"
#define COMMAND_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000002"
#define OTA_CONTROL_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000003"
#define OTA_DATA_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000004"

// -----------------------------------------------------------------------------
// 硬件标识 (Hardware ID) — 随 INFO 特征值上报给 App，App 据此拼出
// …/signal-light/{HARDWARE_ID}/firmware/ 的在线更新路径。将来的新板型
// 用新的 ID，App 无需改动即可按硬件取到各自的固件。
// -----------------------------------------------------------------------------
const String HARDWARE_ID = "esp32c3";

// -----------------------------------------------------------------------------
// 固件版本 (Firmware Version) — bump manually before compiling a new build
// -----------------------------------------------------------------------------
const String FIRMWARE_VERSION = "1.2.1";
#define INFO_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000005"

#endif // CONFIG_H
