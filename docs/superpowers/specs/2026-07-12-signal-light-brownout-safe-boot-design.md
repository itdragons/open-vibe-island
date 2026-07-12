# 信号灯固件异常复位安全降级（Reset-Reason Guarded Safe Boot）设计

## 背景

用户反馈：`signal-light/led_esp32c3/led_esp32c3.ino` 固件运行一段时间后，三色灯开始不断
频闪，App 端蓝牙搜索不到该设备，物理按键也无法触发关机（[[2026-07-11-signal-light-button-deep-sleep-design]]
引入的深度睡眠关机功能失效）。故障现场没有接串口监视器，无法拿到崩溃前后的日志。

设备由内置/外接 LiPo 电池供电，带充电管理模块（非电脑 USB 口供电、非干电池）。

## 根因分析

三个症状同时出现，且都是"运行一段时间后"才出现，指向同一个根因，而非三个独立故障：

**LiPo 电池长时间放电后电压走低，BLE 广播/建连时的电流冲击让供电轨瞬时跌破 ESP32-C3 的
brownout（欠压）检测阈值，芯片反复触发 brownout 复位，陷入"复位 → 重新走 `setup()` →
再次尝试初始化 BLE → 电流冲击 → 再次 brownout"的循环。**

固件当前完全没有电池电压监测逻辑（代码里无任何 ADC 读电压相关代码），brownout 是纯硬件行为，
固件对此没有任何防护——每次复位都会：

- 重新执行 `setup()`：先把三路 LED 拉到熄灭电平再重新初始化，如果复位频率很高（毫秒到百
  毫秒级），肉眼看到的就是频闪。
- 因为还没跑到 `BLEDevice::init` / `advertising->start()` 完整流程就又被打断，BLE 广播
  从未稳定建立，App 自然搜不到设备。
- `checkButton()` 是在 `loop()` 里做的一次性电平沿检测；设备从未稳定停留在 `loop()`，永远
  等不到完整的按下-松开沿，`enterDeepSleep()` 也就无从触发——看起来像按键失灵。

## 设计目标 / 非目标

- **目标**：打断这个复位循环本身。检测到本次启动是异常复位时，不再重新尝试拉起 BLE（它是
  最大的电流冲击源），转而给出一个明显区别于其他模式的警告提示，然后主动进入深度睡眠，把
  控制权交还给用户，由用户按键决定何时重试。
- **非目标**：本设计不消除 brownout 本身（那是电气问题，纯固件方案做不到），也不做真实电池
  电压采集（用户明确选择了纯固件方案，不接受加分压电阻等硬件改动）。如果修复后现象仍然复现，
  再考虑加装真实电压采集。

## 核心机制：复位原因分类

在 `setup()` 最开头（`Serial.begin` 之后、任何 LED/BLE 初始化之前）调用 ESP-IDF 提供的
`esp_reset_reason()`（`esp_system.h`），按复位原因分两类处理：

| 复位原因 | 归类 | 行为 |
|---|---|---|
| `ESP_RST_POWERON`（首次上电/物理插拔电源） | 正常 | 走现有完整流程 |
| `ESP_RST_DEEPSLEEP`（按键 GPIO 唤醒） | 正常 | 走现有完整流程 |
| `ESP_RST_SW`（OTA 成功 / 改名成功后固件自己调用 `ESP.restart()`） | 正常 | 走现有完整流程 |
| `ESP_RST_UNKNOWN`（罕见，通常只出现在芯片刚烧录后的第一次复位） | 正常 | 走现有完整流程（误伤代价高于漏判） |
| `ESP_RST_BROWNOUT` | 异常 | 安全降级分支 |
| `ESP_RST_PANIC` | 异常 | 安全降级分支 |
| `ESP_RST_INT_WDT` | 异常 | 安全降级分支 |
| `ESP_RST_TASK_WDT` | 异常 | 安全降级分支 |
| `ESP_RST_WDT` | 异常 | 安全降级分支 |

`ESP_RST_SW` 必须归入"正常"——OTA 升级和改名功能都依赖固件重启后走完整初始化流程加载新
固件/新名称，如果被误判为异常复位而跳过初始化，会导致 OTA 后设备无法使用。

## 安全降级分支行为

1. 仍然完成三路 LED 引脚 `pinMode`/初始化电平、按键引脚 `pinMode`，以及从 NVS 读取
   `led_red`/`led_yellow`/`led_green` 引脚映射（必须知道当前 R/Y/G 实际接在哪几个 GPIO 上
   才能正确闪灯）——这些都是低功耗操作（GPIO 电平/NVS 闪存读取），不会再次触发 brownout。
2. 调用新增函数 `blinkLowPowerWarning()`：三路 LED **同时**闪烁若干次（现有任何模式都没有
   "三色同亮同灭"这种组合，视觉上足够区别于 `THINKING`/`ALARM`/`ERROR` 等既有效果），使用
   `delay()` 阻塞式实现，不经过 `updateLights()`/`currentMode` 这套渲染机制（此时 BLE 还
   没有初始化，也不需要）。
3. **不调用 `BLEDevice::init()`**，不创建 BLE server/service，不进入正常 `loop()`。
4. 复用 `enterDeepSleep()` 里"等按键释放再使能 GPIO 唤醒"的保护逻辑（见下方边界处理），
   调用 `esp_deep_sleep_enable_gpio_wakeup` + `esp_deep_sleep_start()` 直接进入深度睡眠。
   `setup()` 到此不再返回，`loop()` 不会被调用。

电池若仍未恢复，用户下次按键唤醒时会再次经历"brownout → 复位原因仍是 `ESP_RST_BROWNOUT`
→ 警告闪烁 → 睡眠"，但这是用户每次主动触发的一次性尝试，不会无限空转，也不会比现状更差。

## 边界处理

- **按键唤醒 vs brownout 唤醒必须能区分**：前者复位原因是 `ESP_RST_DEEPSLEEP`，归入正常
  路径，不会被误判为异常复位而反复拒绝启动。
- **OTA / 改名后的主动重启**：复位原因是 `ESP_RST_SW`，归入正常路径，不受本设计影响。
- **安全降级分支里按键恰好被按住**：复用 `enterDeepSleep()` 已有的
  `while (digitalRead(BUTTON_PIN) == LOW) { delay(10); }` 等待释放逻辑，避免刚使能 GPIO
  唤醒就被同一次按压立刻唤醒的死循环——这个风险在安全降级分支里同样存在（触发 brownout 复位
  的那一刻按键状态不可控，理论上可能凑巧是按下状态），因此该保护必须在两处复用同一逻辑，
  不能只在原有 `enterDeepSleep()` 里做。
- **`ESP_RST_UNKNOWN` 归为正常**：宁可在这个罕见场景下继续现有行为（可能复现原症状），
  也不要在无法确定的情况下拒绝启动，避免扩大误伤面。

## 架构与改动

### `led_esp32c3.ino`

- 新增头文件 `#include "esp_system.h"`（`esp_reset_reason()`/`esp_reset_reason_t` 声明处）。
- `setup()`：在 `Serial.println("Wakeup cause: ...")` 之后、`prefs.begin` 之前，新增复位
  原因判断：
  ```cpp
  esp_reset_reason_t resetReason = esp_reset_reason();
  bool isAbnormalReset = resetReason == ESP_RST_BROWNOUT ||
                          resetReason == ESP_RST_PANIC ||
                          resetReason == ESP_RST_INT_WDT ||
                          resetReason == ESP_RST_TASK_WDT ||
                          resetReason == ESP_RST_WDT;
  ```
  之后按 `isAbnormalReset` 分支：仍执行现有的 NVS 读取（引脚映射）+ LED/按键引脚初始化 +
  `turnOffLights()`；若为异常复位，调用新增的 `enterSafeBootSleep()` 并直接返回，不再执行
  `BLEDevice::init()` 及后续所有 BLE 相关初始化。
- 新增函数 `blinkLowPowerWarning()`：三路 LED 同时闪烁固定次数（如 5 次，约 150ms 亮/150ms
  灭），复用现有 `setLights()`。
- 新增函数 `enterSafeBootSleep()`：调用 `blinkLowPowerWarning()`，然后执行与
  `enterDeepSleep()` 相同的"等按键释放 → 使能 GPIO 唤醒 → `esp_deep_sleep_start()`"序列。
  这段等待/唤醒逻辑与 `enterDeepSleep()` 重复，可以从 `enterDeepSleep()` 中抽出一个共享的
  `sleepWithGpioWakeup()` 辅助函数供两处调用，避免逻辑漂移。

### `config.h`

无需改动——不引入新的引脚或持久化配置。

## 测试计划

该固件为 Arduino/ESP32 项目，没有自动化测试框架，且硬件级 brownout 无法在开发环境里干净
复现。验证方式为手动烧录 + 观察：

1. **正常路径不受影响**：正常上电、OTA 升级后重启、改名后重启、按键唤醒——确认都能正常进入
   `MODE_DISCONNECTED` 呼吸态，BLE 可被 App 发现并连接，与修改前行为一致。
2. **安全降级路径**（临时验证）：临时把 `isAbnormalReset` 强制置为 `true` 编译烧录一次，
   确认：
   - 三路 LED 同时闪烁的警告样式清晰可辨，明显区别于呼吸/轮转等现有效果；
   - 警告闪烁结束后设备确实进入深度睡眠（可用功耗表确认电流骤降到深睡眠水平，或观察灯全灭
     且无法通过 BLE 扫描到设备）；
   - 按键可以正常唤醒，唤醒后若复位原因判断已改回真实的 `esp_reset_reason()`，能进入正常
     完整流程。
   - 验证完成后必须改回真实的 `esp_reset_reason()` 判断，重新烧录正式版本。
3. **真实电池耗尽触发 brownout 的完整链路**不在本轮验证范围内（需要数小时的实际耗电测试）。
   如果修复上线后原症状仍然复现，说明需要回来补充真实电压采集（用户此前已知晓并接受这个
   权衡）。
