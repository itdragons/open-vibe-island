# 信号灯按键：长按关机改为短按关机

## 背景

[[2026-07-11-signal-light-button-deep-sleep-design]] 实现了 GPIO0 按键关机（深度睡眠），当前
`checkButton()`（`led_esp32c3.ino:316-332`）要求持续按住满 `BUTTON_HOLD_MS`(800ms) 才触发关机，
目的是过滤校准/接线等手持操作时的瞬间误触。

需求：把这个长按阈值判断去掉，改成点击（按下+松开）即触发关机。

## 需求确认

通过与用户澄清，确定以下行为：

1. **"短按"的定义是"松开即触发"，没有最短按住时长**：只要发生过一次完整的"按下→松开"，
   不管中间按住了多久（哪怕几毫秒），松手瞬间立即触发关机。不是"按下沿立即触发、不等
   释放"，也不要求一个最短按住时长（如 100-300ms）。
2. **误触风险已知并接受**：手持设备、插拔线缆时若无意碰到 GPIO0 并松开，会被当作一次点击
   直接关机。用户明确选择"短按体验优先"，接受这个代价，不需要额外的去抖动/最短时长防护。
3. **按键引脚重新分配/校准范围已收缩为不做**：曾讨论过让 App 端（`calibrate.py`）像
   `PINTEST`/`SETPIN` 校准 LED 引脚一样，支持扫描并重新分配按键引脚（`BUTTON_CANDIDATE_PINS`
   并行扫描 + `SETBUTTON` 命令 + NVS 持久化）。用户认为改动范围太大，决定不实现。
   `BUTTON_PIN` 保持 `config.h` 里的硬编码 `const int = 0`，不接入 NVS，不可重新分配。

## 架构与改动

只涉及 `signal-light/led_esp32c3/led_esp32c3.ino`，不涉及 `config.h`、App 端（`calibrate.py`）、
BLE 协议、NVS。

- 删除常量 `BUTTON_HOLD_MS`（`led_esp32c3.ino:46`）。
- 删除状态变量 `buttonHoldTriggered`（`led_esp32c3.ino:108`）。
- `checkButton()`（`led_esp32c3.ino:316-332`）简化为：检测松开沿
  （`lastButtonState == LOW && buttonState == HIGH`）就直接调用 `enterDeepSleep()`；不再计时、
  不再判断是否达到阈值。
- `enterDeepSleep()` 内部现有的等待释放循环
  `while (digitalRead(BUTTON_PIN) == LOW) { delay(10); }` 保持不动——触发时按键必然已经是
  HIGH，这段循环天然空转，作为安全兜底不需要删除。
- 更新 `checkButton()` 上方的中文注释：说明按键行为从"长按防误触"改为"点击即关机"，并注明
  这是用户明确接受的取舍。

## 边界处理

- 与现有 BLE `OFF`/`CLOSE`/`IDLE` 命令的独立关系不变：按键始终触发真关机（深度睡眠），不受
  `lightOn`/当前模式影响。
- OTA 升级期间按键仍被 `enterDeepSleep()` 开头的 `if (otaActive) return;` 静默忽略，不受本次
  改动影响。
- 误触风险：不做任何去抖动或最短按住时长处理，这是本次改动明确接受的代价（见"需求确认"第 2 条）。

## 测试计划

固件为 Arduino/ESP32 项目，没有自动化测试框架，验证方式为烧录后手动测试：

1. 短暂点按（按下立即松开）→ 立即触发深度睡眠（熄灯、串口打印进入深睡眠日志）。
2. 按住数秒再松开 → 松开瞬间才触发关机，而不是按下的瞬间或满 800ms 时触发。
3. OTA 升级过程中点按按键 → 确认被忽略，OTA 正常完成。
4. 确认 `BUTTON_HOLD_MS`/`buttonHoldTriggered` 已从代码中移除，无残留引用。
