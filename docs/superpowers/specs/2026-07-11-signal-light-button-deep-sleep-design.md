# 信号灯 GPIO0 按键开关机（深度睡眠）设计

## 背景

`signal-light/led_esp32c3/led_esp32c3.ino` 是当前维护的信号灯固件，支持 BLE 控制、OTA 升级、
运行时引脚重分配（`SETPIN`）、接线校准（`PINTEST`）等功能，但没有物理开关机能力。

新一批硬件在 GPIO0 上增加了一枚无自锁按键（轻触后自动弹起，非自锁开关）。需求：

- 按一下按键 → 真正关机（进入深度睡眠，非仅仅熄灯）。
- 再按一下 → 唤醒开机，等效于重新上电。

`signal-light/led_plus_esp32c3/led_plus_esp32c3.ino`（未纳入版本控制的旧原型）已经实现过
GPIO0 按键 + 深度睡眠的基本机制，可作为核心睡眠逻辑的参考，但该文件是重构前的旧版本，
不包含 NVS 引脚配置、OTA 健壮性处理、`SETPIN`/`PINTEST`/亮度/改名等现有功能，且它的按键
逻辑与本设计的行为定义不同（见下文"与旧原型的差异"）。

## 需求确认

通过与用户澄清，确定以下行为：

1. **按键与现有 BLE `OFF`/`CLOSE`/`IDLE` 命令相互独立**：按键任何时候按下都是"真关机"
   （深度睡眠），不受当前 `lightOn`/模式状态影响；`OFF`/`CLOSE`/`IDLE` 命令的软熄灯行为保持不变。
2. **OTA 升级期间按键被静默忽略**：不允许在固件写入过程中断电，避免刷坏固件。
3. **GPIO0 从引脚白名单中移除**：防止用户通过 `SETPIN`/`PINTEST` 把某路 LED 或测试请求
   分配到按键所占用的引脚。
4. **单一固件兼容新旧两款硬件**：旧硬件的 GPIO0 真正悬空、未连接任何元器件，因此无需任何
   编译期区分或运行时硬件探测——同一份固件可以直接刷到两款硬件上。

## 与旧原型的差异

旧原型 `checkButton()` 有 if/else 分支：`lightOn == true` 时才进入深度睡眠；`lightOn == false`
时（此前被 BLE `OFF` 命令软熄灯，芯片仍在运行）按键会被当作"软唤醒"，重新点亮而不触发深度
睡眠。本设计**取消了这个 else 分支**——按键始终触发深度睡眠，不管之前是否被 BLE 命令软熄灯过。

## 架构与改动

### `config.h`

- 新增按键引脚常量：`const int BUTTON_PIN = 0;`（与 LED 默认引脚常量放在一起，但不经 NVS
  持久化——这是物理按键固定接线，不像 LED 引脚那样需要运行时重新分配）。
- `SAFE_GPIO_PINS` 移除 `0`，`SAFE_GPIO_PIN_COUNT` 由 13 改为 12。

### `led_esp32c3.ino`

- 新增头文件 `#include <esp_sleep.h>`。
- 新增全局状态 `bool lastButtonState = HIGH;`。
- `setup()`：
  - 在现有 LED `pinMode` 初始化之后，新增
    `pinMode(BUTTON_PIN, INPUT_PULLUP); lastButtonState = digitalRead(BUTTON_PIN);`，
    替换掉现有的"未接实体按键，无需初始化按键引脚"注释。
  - 新增一行诊断日志，打印 `esp_sleep_get_wakeup_cause()`，用于串口调试确认唤醒来源
    （不影响任何业务逻辑，纯诊断输出）。
- `loop()`：将现有的 `// checkButton();` 占位注释替换为真正的调用，放在现有的 OTA 延迟重启
  /串口指令/PINTEST 超时检查之前，与旧原型的调用位置一致。
- 新增 `checkButton()`：
  - 检测 `HIGH → LOW` 下降沿。
  - 命中后 `delay(200)` 做阻塞式防抖（与文件中现有的阻塞延迟风格一致，如
    `BLE_RECONNECT_DELAY_MS` 的用法），然后调用 `enterDeepSleep()`。
  - 不判断当前 `lightOn`/`currentMode`，任何状态下按下都尝试关机。
- 新增 `enterDeepSleep()`：
  - `if (otaActive) return;` 保护，OTA 期间静默忽略。
  - `turnOffLights()` 熄灭三路 LED。
  - 忙等按键释放：`while (digitalRead(BUTTON_PIN) == LOW) { delay(10); }`，再加一个短暂
    settle delay，防止按键还未松开就使能唤醒导致刚进深睡眠又被同一次按压唤醒。
  - `esp_deep_sleep_enable_gpio_wakeup(1ULL << BUTTON_PIN, ESP_GPIO_WAKEUP_GPIO_LOW);`
  - `esp_deep_sleep_start();`

### 唤醒行为

GPIO 唤醒会触发芯片复位，`setup()` 重新执行一次完整的冷启动流程（读取 NVS 引脚/蓝牙名称、
初始化 BLE、进入 `MODE_DISCONNECTED` 三色呼吸等待重连），与正常上电行为完全一致，不需要
额外的"唤醒后状态恢复"代码。

## 边界处理

- **OTA 保护**：`enterDeepSleep()` 开头即返回，OTA 数据传输/结束不会被打断。
- **防抖**：200ms 阻塞延迟足以过滤机械按键的抖动，且关机是低频操作，不影响 BLE/OTA 的
  正常响应。
- **深度睡眠前必须等待按键释放**：避免"按下→熄灯→立刻又被同一次按压唤醒"的死循环。
- **引脚冲突防护**：`SAFE_GPIO_PINS` 已移除 `0`，`SETPIN:*:0` 与 `PINTEST:0:*` 会被现有的
  白名单校验直接拒绝（返回 `"unsupported pin 0"`），无需新增专门的冲突检测代码。
- **硬件兼容性**：旧硬件 GPIO0 真正悬空，内部上拉电阻使其稳定读 HIGH，`checkButton()` 永远
  检测不到下降沿，不会误触发关机；新硬件按键工作方式如上所述。两者共用同一份固件。

## 测试计划

该固件为 Arduino/ESP32 项目，没有自动化测试框架，验证方式为手动烧录 + 观察：

1. 灯亮着按一下按键 → 灯熄灭、串口打印进入深度睡眠日志、可用功耗表确认电流骤降到深睡眠
   水平（而不只是熄灯）。
2. 再按一下按键 → 芯片复位重启，串口重新打印启动日志，进入未连接呼吸态，BLE 广播恢复，
   App 可重新连接。
3. OTA 升级过程中按下按键 → 确认被忽略，OTA 正常完成，不会中断刷写。
4. 发送 `SETPIN:R:0` 或 `PINTEST:0:1` → 确认被拒绝，返回 `"unsupported pin 0"`。
5. （若有旧硬件实物）在没有接按键的旧硬件上烧录同一固件，确认长时间运行不会误触发关机。
