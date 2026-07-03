#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// -----------------------------------------------------------------------------
// 引脚配置 (Pin Configuration)
// -----------------------------------------------------------------------------
const int led_red = 5;
const int led_yellow = 6;
const int led_green = 7;

// -----------------------------------------------------------------------------
// 蓝牙配置 (BLE Configuration)
// -----------------------------------------------------------------------------
const String BLE_DEVICE_NAME = "drg5"; // 蓝牙设备名称配置

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
