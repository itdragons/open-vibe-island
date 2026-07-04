# Signal Light Field Configuration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an end user fix a mis-wired signal light, tell identical units apart, dim the light, and switch it fully off — all from the app, over BLE, using the exact same firmware binary on every unit.

**Architecture:** Firmware moves pin assignments and the BLE name from `config.h` compile-time constants into ESP32 NVS (`Preferences`), falling back to the `config.h` defaults when nothing's stored yet. Five new text commands (`SETPIN`, `PINTEST`, `GETCONFIG`, `SETNAME`, `BRIGHTNESS`) extend the existing single-characteristic protocol. The light switch needs no new firmware command at all — it reuses the existing `OFF`/`EFFECT:` behavior, plus one bug fix so `PINTEST` still works while the light is switched off. On the app side, two new pure types land in `OpenIslandCore` (raw command encoding/decoding, and a calibration-wizard state machine), `SignalLightCoordinator` gains raw-send plus a couple of state flags, `AppModel` gains two persisted preferences, and `SignalLightSettingsPane` gains a light switch, rename field, brightness slider, and a wiring-calibration wizard sheet.

**Tech Stack:** Swift 6.2, SwiftUI, CoreBluetooth (macOS 14+), Arduino/ESP32-C3 C++ (`Preferences.h`).

## Global Constraints

- Do not use TDD for this work — write the implementation directly, no failing-test-first steps. (Explicit user instruction.) Pure-logic additions to `OpenIslandCore` (command encoding, config decoding, the calibration wizard) still get regression tests, matching this codebase's existing `SignalLightTests.swift` convention — written together with the implementation, not before it. CoreBluetooth/SwiftUI-facing code (`SignalLightCoordinator`, `SignalLightSettingsPane`) has no automated tests, verified manually instead — matches this codebase's existing convention (see `docs/superpowers/plans/2026-07-04-signal-light-firmware-ota.md`'s Global Constraints).
- The signal-light BLE OTA feature (firmware version characteristic, `SignalLightFirmwareUpdater`, OTA control/data/info characteristic discovery in `SignalLightCoordinator`) is **already implemented and merged** on this branch. Reuse its existing `otaControlCharacteristicUUID` constant, characteristic discovery, and notify subscription — do not re-add or duplicate them.
- Minimal-footprint / additive firmware changes: no existing command, mode, or OTA logic in `led_esp32c3.ino` is modified or removed except the two single-line fixes called out explicitly in Task 1 and Task 4 (both required for compilation/correctness, not stylistic).
- Follow existing project conventions: `.withResponse` for signal light BLE writes, `@Observable`/`@ObservationIgnored` patterns already used in `SignalLightCoordinator.swift`, and the localization pattern of `lang.t("settings.signalLight.<key>")` with matching entries in all three `Localizable.strings` files.
- Firmware safe-GPIO allow-list is `{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 21}` (ESP32-C3 Super Mini usable pins, excluding native-USB pins 18/19). It lives in one array (`SAFE_GPIO_PINS` in `config.h`) — if the real board's usable-pin set differs, that's the only line to change.
- Design spec: `docs/superpowers/specs/2026-07-04-signal-light-field-config-design.md`. Refer to it for full rationale — this plan implements it as-is.

---

### Task 1: Firmware — runtime-configurable pins & BLE name (NVS)

**Files:**
- Modify: `signal-light/led_esp32c3/config.h`
- Modify: `signal-light/led_esp32c3/led_esp32c3.ino`

**Interfaces:**
- Produces (consumed by Tasks 2–5): `DEFAULT_LED_RED`/`DEFAULT_LED_YELLOW`/`DEFAULT_LED_GREEN`, `SAFE_GPIO_PINS`/`SAFE_GPIO_PIN_COUNT`, `BLE_NAME_PREFIX` (all in `config.h`); mutable globals `led_red`/`led_yellow`/`led_green`/`bleName` and `Preferences prefs` (in the `.ino`); `bool isSafeGpioPin(int pin)`.

- [ ] **Step 1: Replace the pin/name constants in `config.h` with defaults + a safe-pin list**

In `signal-light/led_esp32c3/config.h`, replace:

```cpp
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
```

with:

```cpp
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
// 首次开机会自动生成 "WG-<芯片ID后4位>" 并写入，保证开箱即可区分设备。
// -----------------------------------------------------------------------------
const String BLE_NAME_PREFIX = "WG-";
```

- [ ] **Step 2: Add `Preferences` and the runtime pin/name globals in `led_esp32c3.ino`**

In `signal-light/led_esp32c3/led_esp32c3.ino`, replace:

```cpp
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Update.h>
#include "config.h"


// ESP32-C3 Super Mini supports BLE, but not BluetoothSerial.
// Use the BLE device named C3_LED to control the lights and send firmware OTA.


bool lightOn = true;
```

with:

```cpp
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Update.h>
#include <Preferences.h>
#include "config.h"


// ESP32-C3 Super Mini supports BLE, but not BluetoothSerial.
// Use the BLE device named C3_LED to control the lights and send firmware OTA.


Preferences prefs;

// Runtime pin assignment and BLE name — loaded from NVS in setup(), falling
// back to the config.h defaults on a fresh chip. Reassignable at runtime via
// SETPIN/SETNAME without reflashing.
int led_red = DEFAULT_LED_RED;
int led_yellow = DEFAULT_LED_YELLOW;
int led_green = DEFAULT_LED_GREEN;
String bleName;

bool lightOn = true;
```

- [ ] **Step 3: Add the `isSafeGpioPin` forward declaration**

Replace:

```cpp
void handleCommand(String cmd);
void handleOtaControl(String cmd);
void handleOtaData(BLECharacteristic *characteristic);
void setOtaStatus(const String &message);
void startMode(LedMode mode);
bool isCommand(String cmd, String a, String b = "", String c = "", String d = "");
void handleEffectCommand(String cmd);
void animateCustomEffect(unsigned long nowMs);
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex);
```

with:

```cpp
void handleCommand(String cmd);
void handleOtaControl(String cmd);
void handleOtaData(BLECharacteristic *characteristic);
void setOtaStatus(const String &message);
void startMode(LedMode mode);
bool isCommand(String cmd, String a, String b = "", String c = "", String d = "");
void handleEffectCommand(String cmd);
void animateCustomEffect(unsigned long nowMs);
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex);
bool isSafeGpioPin(int pin);
```

- [ ] **Step 4: Load pin/name from NVS in `setup()`, generating a unique name on first boot**

Replace:

```cpp
  Serial.println();
  Serial.println("============================");
  Serial.println("C3 LED starting...");

  pinMode(led_green, OUTPUT);
  pinMode(led_red, OUTPUT);
  pinMode(led_yellow, OUTPUT);
  // No physical button configured

  showManualLights();

  BLEDevice::init(BLE_DEVICE_NAME.c_str());
  BLEDevice::setMTU(517);
```

with:

```cpp
  Serial.println();
  Serial.println("============================");
  Serial.println("C3 LED starting...");

  prefs.begin("wglight", false);
  led_red = prefs.getInt("pinRed", DEFAULT_LED_RED);
  led_yellow = prefs.getInt("pinYellow", DEFAULT_LED_YELLOW);
  led_green = prefs.getInt("pinGreen", DEFAULT_LED_GREEN);
  bleName = prefs.getString("bleName", "");
  if (bleName.length() == 0) {
    uint64_t chipId = ESP.getEfuseMac();
    char suffix[5];
    snprintf(suffix, sizeof(suffix), "%04X", (uint16_t)(chipId & 0xFFFF));
    bleName = BLE_NAME_PREFIX + String(suffix);
    prefs.putString("bleName", bleName);
  }
  Serial.println("Pins -> R:" + String(led_red) + " Y:" + String(led_yellow) + " G:" + String(led_green));
  Serial.println("BLE name -> " + bleName);

  pinMode(led_green, OUTPUT);
  pinMode(led_red, OUTPUT);
  pinMode(led_yellow, OUTPUT);
  // No physical button configured

  showManualLights();

  BLEDevice::init(bleName.c_str());
  BLEDevice::setMTU(517);
```

- [ ] **Step 5: Fix the `BLE` debug command's now-removed `BLE_DEVICE_NAME` reference**

Replace:

```cpp
  if (cmd == "BLE") {
    Serial.println("Bluetooth Name: " + BLE_DEVICE_NAME);
    return;
  }
```

with:

```cpp
  if (cmd == "BLE") {
    Serial.println("Bluetooth Name: " + bleName);
    return;
  }
```

- [ ] **Step 6: Add the `isSafeGpioPin` helper at the end of the file**

Replace:

```cpp
bool isCommand(String cmd, String a, String b, String c, String d) {
  return cmd == a || cmd == b || cmd == c || cmd == d;
}
```

with:

```cpp
bool isCommand(String cmd, String a, String b, String c, String d) {
  return cmd == a || cmd == b || cmd == c || cmd == d;
}

bool isSafeGpioPin(int pin) {
  for (int i = 0; i < SAFE_GPIO_PIN_COUNT; i++) {
    if (SAFE_GPIO_PINS[i] == pin) {
      return true;
    }
  }
  return false;
}
```

- [ ] **Step 7: Verify it compiles**

If `arduino-cli` is available, run from `signal-light/led_esp32c3/`:
```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3 .
```
Expected: compiles with no errors.

If `arduino-cli` isn't installed, open `led_esp32c3.ino` in the Arduino IDE and use Sketch → Verify/Compile instead. Either way, confirm before moving on — firmware isn't flashed to a real board until Task 13.

- [ ] **Step 8: Commit**

```bash
git add signal-light/led_esp32c3/config.h signal-light/led_esp32c3/led_esp32c3.ino
git commit -m "feat(firmware): load pin assignment and BLE name from NVS with factory-unique default name"
```

---

### Task 2: Firmware — `SETPIN` and `GETCONFIG` commands

**Files:**
- Modify: `signal-light/led_esp32c3/led_esp32c3.ino`

**Interfaces:**
- Consumes: `led_red`/`led_yellow`/`led_green`/`bleName`/`prefs`/`isSafeGpioPin` from Task 1.
- Produces (consumed by Task 3): forward decls and definitions of `void handleSetPinCommand(String cmd)`, `void sendConfigStatus()`.

- [ ] **Step 1: Add forward declarations**

Replace:

```cpp
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex);
bool isSafeGpioPin(int pin);
```

with:

```cpp
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex);
bool isSafeGpioPin(int pin);
void handleSetPinCommand(String cmd);
void sendConfigStatus();
```

- [ ] **Step 2: Dispatch the new commands in `handleCommand`**

Replace:

```cpp
  if (cmd.startsWith("EFFECT:")) {
    handleEffectCommand(cmd);
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

with:

```cpp
  if (cmd.startsWith("EFFECT:")) {
    handleEffectCommand(cmd);
    return;
  }

  if (cmd.startsWith("SETPIN:")) {
    handleSetPinCommand(cmd);
    return;
  }

  if (cmd == "GETCONFIG") {
    sendConfigStatus();
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

- [ ] **Step 3: Add the handler implementations at the end of the file**

Replace:

```cpp
bool isSafeGpioPin(int pin) {
  for (int i = 0; i < SAFE_GPIO_PIN_COUNT; i++) {
    if (SAFE_GPIO_PINS[i] == pin) {
      return true;
    }
  }
  return false;
}
```

with:

```cpp
bool isSafeGpioPin(int pin) {
  for (int i = 0; i < SAFE_GPIO_PIN_COUNT; i++) {
    if (SAFE_GPIO_PINS[i] == pin) {
      return true;
    }
  }
  return false;
}

void handleSetPinCommand(String cmd) {
  // Format: SETPIN:<R|Y|G>:<pin>, e.g. SETPIN:R:10
  int firstColon = cmd.indexOf(':');
  int secondColon = cmd.indexOf(':', firstColon + 1);
  if (firstColon < 0 || secondColon < 0) {
    setOtaStatus("SETPIN failed: malformed command");
    return;
  }

  String colorText = cmd.substring(firstColon + 1, secondColon);
  int pin = cmd.substring(secondColon + 1).toInt();

  if (!isSafeGpioPin(pin)) {
    setOtaStatus("SETPIN failed: unsupported pin " + String(pin));
    return;
  }

  pinMode(pin, OUTPUT);

  if (colorText == "R") {
    led_red = pin;
    prefs.putInt("pinRed", pin);
  } else if (colorText == "Y") {
    led_yellow = pin;
    prefs.putInt("pinYellow", pin);
  } else if (colorText == "G") {
    led_green = pin;
    prefs.putInt("pinGreen", pin);
  } else {
    setOtaStatus("SETPIN failed: unknown color " + colorText);
    return;
  }

  setOtaStatus("SETPIN ok: " + colorText + "=" + String(pin));
}

void sendConfigStatus() {
  String status = "CONFIG:R=" + String(led_red) +
                   ",Y=" + String(led_yellow) +
                   ",G=" + String(led_green) +
                   ",NAME=" + bleName;
  setOtaStatus(status);
}
```

- [ ] **Step 4: Verify it compiles**

```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3 signal-light/led_esp32c3/
```
(Or Arduino IDE Verify/Compile.) Expected: compiles with no errors.

- [ ] **Step 5: Commit**

```bash
git add signal-light/led_esp32c3/led_esp32c3.ino
git commit -m "feat(firmware): add SETPIN and GETCONFIG commands"
```

---

### Task 3: Firmware — `PINTEST` wiring-test mode + light-switch interaction fix

**Files:**
- Modify: `signal-light/led_esp32c3/led_esp32c3.ino`

**Interfaces:**
- Consumes: `isSafeGpioPin`, `setOtaStatus` from earlier tasks.
- Produces (consumed by Task 6/12 indirectly via the `PINTEST` wire protocol): `MODE_PIN_TEST` enum case, `void handlePinTestCommand(String cmd)`, `void endPinTestIfExpired(unsigned long nowMs)`.
- This task is also what makes the **light switch** feature (spec section "Light switch (standby)") correct — no separate firmware task exists for it, since the existing `OFF`/`EFFECT:` commands already implement it. The only firmware gap was `PINTEST` being silently ignored while the light is switched off, which this task fixes.

- [ ] **Step 1: Add `MODE_PIN_TEST` to the mode enum**

Replace:

```cpp
enum LedMode {
  MODE_MANUAL,
  MODE_GREEN_BLINK,
  MODE_THINKING,
  MODE_WORKING,
  MODE_BUSY,
  MODE_SUCCESS,
  MODE_ERROR,
  MODE_ALARM,
  MODE_CUSTOM_EFFECT
};
```

with:

```cpp
enum LedMode {
  MODE_MANUAL,
  MODE_GREEN_BLINK,
  MODE_THINKING,
  MODE_WORKING,
  MODE_BUSY,
  MODE_SUCCESS,
  MODE_ERROR,
  MODE_ALARM,
  MODE_CUSTOM_EFFECT,
  MODE_PIN_TEST
};
```

- [ ] **Step 2: Add pin-test state globals**

Replace:

```cpp
LedMode currentMode = MODE_MANUAL;
unsigned long lastFrameMs = 0;
int frame = 0;

enum CustomEffectType {
```

with:

```cpp
LedMode currentMode = MODE_MANUAL;
unsigned long lastFrameMs = 0;
int frame = 0;

// Wiring-calibration pin-test state (see handlePinTestCommand). Isolated
// from the effect-rendering modes above so a PINTEST sequence can't be
// silently overwritten by, or overwrite, a live EFFECT: push.
int pinTestActivePin = -1;
bool pinTestPriorLightOn = true;
LedMode pinTestPriorMode = MODE_MANUAL;
unsigned long pinTestDeadlineMs = 0;

enum CustomEffectType {
```

- [ ] **Step 3: Add forward declarations**

Replace:

```cpp
void handleSetPinCommand(String cmd);
void sendConfigStatus();
```

with:

```cpp
void handleSetPinCommand(String cmd);
void sendConfigStatus();
void handlePinTestCommand(String cmd);
void endPinTestIfExpired(unsigned long nowMs);
```

- [ ] **Step 4: Dispatch `PINTEST:` in `handleCommand`**

Replace:

```cpp
  if (cmd == "GETCONFIG") {
    sendConfigStatus();
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

with:

```cpp
  if (cmd == "GETCONFIG") {
    sendConfigStatus();
    return;
  }

  if (cmd.startsWith("PINTEST:")) {
    handlePinTestCommand(cmd);
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

- [ ] **Step 5: Check for pin-test expiry every loop iteration, before the light-switch early return**

Replace:

```cpp
  // checkButton(); // removed

  if (!lightOn) {
    turnOffLights();
    return;
  }

  updateLights();
}
```

with:

```cpp
  // checkButton(); // removed

  endPinTestIfExpired(millis());

  if (!lightOn) {
    turnOffLights();
    return;
  }

  updateLights();
}
```

- [ ] **Step 6: Add a no-op render branch for `MODE_PIN_TEST`**

Replace:

```cpp
  } else if (currentMode == MODE_CUSTOM_EFFECT) {
    animateCustomEffect(nowMs);
  }
}
```

with:

```cpp
  } else if (currentMode == MODE_CUSTOM_EFFECT) {
    animateCustomEffect(nowMs);
  } else if (currentMode == MODE_PIN_TEST) {
    // Pin driven directly by handlePinTestCommand(); nothing to render here.
  }
}
```

- [ ] **Step 7: Add the handler implementations at the end of the file**

Replace:

```cpp
void sendConfigStatus() {
  String status = "CONFIG:R=" + String(led_red) +
                   ",Y=" + String(led_yellow) +
                   ",G=" + String(led_green) +
                   ",NAME=" + bleName;
  setOtaStatus(status);
}
```

with:

```cpp
void sendConfigStatus() {
  String status = "CONFIG:R=" + String(led_red) +
                   ",Y=" + String(led_yellow) +
                   ",G=" + String(led_green) +
                   ",NAME=" + bleName;
  setOtaStatus(status);
}

void handlePinTestCommand(String cmd) {
  // Format: PINTEST:<pin>:<0|1>
  int firstColon = cmd.indexOf(':');
  int secondColon = cmd.indexOf(':', firstColon + 1);
  if (firstColon < 0 || secondColon < 0) {
    setOtaStatus("PINTEST failed: malformed command");
    return;
  }

  int pin = cmd.substring(firstColon + 1, secondColon).toInt();
  int value = cmd.substring(secondColon + 1).toInt();

  if (!isSafeGpioPin(pin)) {
    setOtaStatus("PINTEST failed: unsupported pin " + String(pin));
    return;
  }

  if (currentMode != MODE_PIN_TEST) {
    // Entering test mode for the first time this sequence: remember what to
    // restore, and force the light on even if it was switched off, so the
    // wizard works regardless of the light-switch state.
    pinTestPriorLightOn = lightOn;
    pinTestPriorMode = currentMode;
    lightOn = true;
    currentMode = MODE_PIN_TEST;
  } else if (pinTestActivePin != -1 && pinTestActivePin != pin) {
    // Switching to a different candidate pin mid-wizard: turn the previous
    // one off so it doesn't stay lit if the app forgets to.
    analogWrite(pinTestActivePin, LED_OFF);
  }

  pinMode(pin, OUTPUT);
  analogWrite(pin, value == 1 ? LED_ON : LED_OFF);
  pinTestActivePin = pin;
  pinTestDeadlineMs = millis() + 5000;
}

void endPinTestIfExpired(unsigned long nowMs) {
  if (currentMode != MODE_PIN_TEST || nowMs < pinTestDeadlineMs) {
    return;
  }

  if (pinTestActivePin != -1) {
    analogWrite(pinTestActivePin, LED_OFF);
  }
  pinTestActivePin = -1;
  lightOn = pinTestPriorLightOn;
  currentMode = pinTestPriorMode;
}
```

- [ ] **Step 8: Verify it compiles**

```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3 signal-light/led_esp32c3/
```
Expected: compiles with no errors.

- [ ] **Step 9: Commit**

```bash
git add signal-light/led_esp32c3/led_esp32c3.ino
git commit -m "feat(firmware): add PINTEST wiring-test mode and fix light-switch interaction"
```

---

### Task 4: Firmware — `SETNAME` command with delayed restart

**Files:**
- Modify: `signal-light/led_esp32c3/led_esp32c3.ino`

**Interfaces:**
- Consumes: `prefs`, `setOtaStatus` from earlier tasks.
- Produces: `void handleSetNameCommand(String cmd)`, globals `restartAfterRename`/`restartAfterRenameAtMs`.

- [ ] **Step 1: Add restart-after-rename globals, alongside the existing OTA restart globals**

Replace:

```cpp
bool otaActive = false;
bool restartAfterOta = false;
size_t otaExpectedSize = UPDATE_SIZE_UNKNOWN;
size_t otaWrittenBytes = 0;
unsigned long restartAtMs = 0;
```

with:

```cpp
bool otaActive = false;
bool restartAfterOta = false;
size_t otaExpectedSize = UPDATE_SIZE_UNKNOWN;
size_t otaWrittenBytes = 0;
unsigned long restartAtMs = 0;

bool restartAfterRename = false;
unsigned long restartAfterRenameAtMs = 0;
```

- [ ] **Step 2: Add the forward declaration**

Replace:

```cpp
void handlePinTestCommand(String cmd);
void endPinTestIfExpired(unsigned long nowMs);
```

with:

```cpp
void handlePinTestCommand(String cmd);
void endPinTestIfExpired(unsigned long nowMs);
void handleSetNameCommand(String cmd);
```

- [ ] **Step 3: Preserve the original (non-uppercased) command text and dispatch `SETNAME:`**

`handleCommand` uppercases `cmd` for keyword matching, which would mangle a user-chosen mixed-case name — so this step keeps a trimmed-but-original-case copy specifically for `SETNAME`.

Replace:

```cpp
void handleCommand(String cmd) {
  cmd.trim();
  cmd.toUpperCase();

  if (cmd.length() == 0) {
    return;
  }

  if (cmd.startsWith("EFFECT:")) {
    handleEffectCommand(cmd);
    return;
  }

  if (cmd.startsWith("SETPIN:")) {
    handleSetPinCommand(cmd);
    return;
  }

  if (cmd == "GETCONFIG") {
    sendConfigStatus();
    return;
  }

  if (cmd.startsWith("PINTEST:")) {
    handlePinTestCommand(cmd);
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

with:

```cpp
void handleCommand(String cmd) {
  String original = cmd;
  original.trim();
  cmd.trim();
  cmd.toUpperCase();

  if (cmd.length() == 0) {
    return;
  }

  if (cmd.startsWith("EFFECT:")) {
    handleEffectCommand(cmd);
    return;
  }

  if (cmd.startsWith("SETPIN:")) {
    handleSetPinCommand(cmd);
    return;
  }

  if (cmd == "GETCONFIG") {
    sendConfigStatus();
    return;
  }

  if (cmd.startsWith("PINTEST:")) {
    handlePinTestCommand(cmd);
    return;
  }

  if (cmd.startsWith("SETNAME:")) {
    handleSetNameCommand(original);
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

- [ ] **Step 4: Check the rename restart timer in `loop()`, alongside the existing OTA restart timer**

Replace:

```cpp
void loop() {
  if (restartAfterOta && millis() >= restartAtMs) {
    ESP.restart();
  }

  if (Serial.available() > 0) {
```

with:

```cpp
void loop() {
  if (restartAfterOta && millis() >= restartAtMs) {
    ESP.restart();
  }

  if (restartAfterRename && millis() >= restartAfterRenameAtMs) {
    ESP.restart();
  }

  if (Serial.available() > 0) {
```

- [ ] **Step 5: Add the handler implementation at the end of the file**

Replace:

```cpp
void endPinTestIfExpired(unsigned long nowMs) {
  if (currentMode != MODE_PIN_TEST || nowMs < pinTestDeadlineMs) {
    return;
  }

  if (pinTestActivePin != -1) {
    analogWrite(pinTestActivePin, LED_OFF);
  }
  pinTestActivePin = -1;
  lightOn = pinTestPriorLightOn;
  currentMode = pinTestPriorMode;
}
```

with:

```cpp
void endPinTestIfExpired(unsigned long nowMs) {
  if (currentMode != MODE_PIN_TEST || nowMs < pinTestDeadlineMs) {
    return;
  }

  if (pinTestActivePin != -1) {
    analogWrite(pinTestActivePin, LED_OFF);
  }
  pinTestActivePin = -1;
  lightOn = pinTestPriorLightOn;
  currentMode = pinTestPriorMode;
}

void handleSetNameCommand(String cmd) {
  // Format: SETNAME:<name> — `cmd` here is the ORIGINAL (non-uppercased)
  // command text so the chosen name keeps its case.
  int firstColon = cmd.indexOf(':');
  if (firstColon < 0) {
    setOtaStatus("SETNAME failed: malformed command");
    return;
  }

  String newName = cmd.substring(firstColon + 1);
  newName.trim();
  if (newName.length() == 0) {
    setOtaStatus("SETNAME failed: empty name");
    return;
  }

  prefs.putString("bleName", newName);
  setOtaStatus("SETNAME ok, restarting");
  restartAfterRename = true;
  restartAfterRenameAtMs = millis() + 3000;
}
```

- [ ] **Step 6: Verify it compiles**

```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3 signal-light/led_esp32c3/
```
Expected: compiles with no errors.

- [ ] **Step 7: Commit**

```bash
git add signal-light/led_esp32c3/led_esp32c3.ino
git commit -m "feat(firmware): add SETNAME command with delayed restart"
```

---

### Task 5: Firmware — `BRIGHTNESS` command + brightness-scaled rendering

**Files:**
- Modify: `signal-light/led_esp32c3/led_esp32c3.ino`

**Interfaces:**
- Produces: `int brightnessPercent` (global, default 100), `int currentOnValue()`, `void handleBrightnessCommand(String cmd)`.

- [ ] **Step 1: Add the brightness global**

Replace:

```cpp
const int LED_ON = 0; // 0 是全亮（低电平）
const int LED_DIM = 128; // 半亮
const int LED_OFF = 255; // 255 是全灭（高电平）
const int PWM_MIN = 0;
const int PWM_MAX = 255;

int redValue = LED_ON;
```

with:

```cpp
const int LED_ON = 0; // 0 是全亮（低电平）
const int LED_DIM = 128; // 半亮
const int LED_OFF = 255; // 255 是全灭（高电平）
const int PWM_MIN = 0;
const int PWM_MAX = 255;

int brightnessPercent = 100; // 0-100，通过 BRIGHTNESS 命令调节；App 重连后会重新同步

int redValue = LED_ON;
```

- [ ] **Step 2: Add the forward declarations**

Replace:

```cpp
void handleSetNameCommand(String cmd);
```

with:

```cpp
void handleSetNameCommand(String cmd);
void handleBrightnessCommand(String cmd);
int currentOnValue();
```

- [ ] **Step 3: Add `currentOnValue()` next to `breathValue()`**

Replace:

```cpp
int breathValue(unsigned long nowMs, unsigned long periodMs) {
```

with:

```cpp
int currentOnValue() {
  return map(brightnessPercent, 0, 100, LED_OFF, LED_ON);
}

int breathValue(unsigned long nowMs, unsigned long periodMs) {
```

- [ ] **Step 4: Apply brightness scaling in `animateCustomEffect`**

Replace:

```cpp
void animateCustomEffect(unsigned long nowMs) {
  if (customEffectColorCount == 0) {
    return;
  }

  int red = LED_OFF;
  int yellow = LED_OFF;
  int green = LED_OFF;

  if (customEffectType == EFFECT_SOLID) {
    applyCustomEffectValue(red, yellow, green, LED_ON, -1);
  } else if (customEffectType == EFFECT_BLINK) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    bool on = (nowMs / interval) % 2 == 0;
    applyCustomEffectValue(red, yellow, green, on ? LED_ON : LED_OFF, -1);
  } else if (customEffectType == EFFECT_CYCLE) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int activeIndex = (int)((nowMs / interval) % customEffectColorCount);
    applyCustomEffectValue(red, yellow, green, LED_ON, activeIndex);
  } else if (customEffectType == EFFECT_BREATHE) {
    unsigned long period = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int value = breathValue(nowMs, period);
    applyCustomEffectValue(red, yellow, green, value, -1);
  }

  setLights(red, yellow, green);
}
```

with:

```cpp
void animateCustomEffect(unsigned long nowMs) {
  if (customEffectColorCount == 0) {
    return;
  }

  int red = LED_OFF;
  int yellow = LED_OFF;
  int green = LED_OFF;
  int onValue = currentOnValue();

  if (customEffectType == EFFECT_SOLID) {
    applyCustomEffectValue(red, yellow, green, onValue, -1);
  } else if (customEffectType == EFFECT_BLINK) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    bool on = (nowMs / interval) % 2 == 0;
    applyCustomEffectValue(red, yellow, green, on ? onValue : LED_OFF, -1);
  } else if (customEffectType == EFFECT_CYCLE) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int activeIndex = (int)((nowMs / interval) % customEffectColorCount);
    applyCustomEffectValue(red, yellow, green, onValue, activeIndex);
  } else if (customEffectType == EFFECT_BREATHE) {
    unsigned long period = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int rawValue = breathValue(nowMs, period);
    int scaledValue = map(rawValue, LED_ON, LED_OFF, onValue, LED_OFF);
    applyCustomEffectValue(red, yellow, green, scaledValue, -1);
  }

  setLights(red, yellow, green);
}
```

- [ ] **Step 5: Dispatch `BRIGHTNESS:` in `handleCommand`**

Replace:

```cpp
  if (cmd.startsWith("SETNAME:")) {
    handleSetNameCommand(original);
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

with:

```cpp
  if (cmd.startsWith("SETNAME:")) {
    handleSetNameCommand(original);
    return;
  }

  if (cmd.startsWith("BRIGHTNESS:")) {
    handleBrightnessCommand(cmd);
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

- [ ] **Step 6: Add the handler implementation at the end of the file**

Replace:

```cpp
void handleSetNameCommand(String cmd) {
  // Format: SETNAME:<name> — `cmd` here is the ORIGINAL (non-uppercased)
  // command text so the chosen name keeps its case.
  int firstColon = cmd.indexOf(':');
  if (firstColon < 0) {
    setOtaStatus("SETNAME failed: malformed command");
    return;
  }

  String newName = cmd.substring(firstColon + 1);
  newName.trim();
  if (newName.length() == 0) {
    setOtaStatus("SETNAME failed: empty name");
    return;
  }

  prefs.putString("bleName", newName);
  setOtaStatus("SETNAME ok, restarting");
  restartAfterRename = true;
  restartAfterRenameAtMs = millis() + 3000;
}
```

with:

```cpp
void handleSetNameCommand(String cmd) {
  // Format: SETNAME:<name> — `cmd` here is the ORIGINAL (non-uppercased)
  // command text so the chosen name keeps its case.
  int firstColon = cmd.indexOf(':');
  if (firstColon < 0) {
    setOtaStatus("SETNAME failed: malformed command");
    return;
  }

  String newName = cmd.substring(firstColon + 1);
  newName.trim();
  if (newName.length() == 0) {
    setOtaStatus("SETNAME failed: empty name");
    return;
  }

  prefs.putString("bleName", newName);
  setOtaStatus("SETNAME ok, restarting");
  restartAfterRename = true;
  restartAfterRenameAtMs = millis() + 3000;
}

void handleBrightnessCommand(String cmd) {
  // Format: BRIGHTNESS:<0-100>
  int colonIndex = cmd.indexOf(':');
  if (colonIndex < 0) {
    setOtaStatus("BRIGHTNESS failed: malformed command");
    return;
  }

  int percent = cmd.substring(colonIndex + 1).toInt();
  brightnessPercent = constrain(percent, 0, 100);
}
```

- [ ] **Step 7: Verify it compiles**

```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3 signal-light/led_esp32c3/
```
Expected: compiles with no errors. This is the last firmware task — the `.ino`/`config.h` are done until Task 13's physical flash.

- [ ] **Step 8: Commit**

```bash
git add signal-light/led_esp32c3/led_esp32c3.ino
git commit -m "feat(firmware): add BRIGHTNESS command and brightness-scaled rendering"
```

---

### Task 6: Core — raw control commands + config decoder

**Files:**
- Modify: `Sources/OpenIslandCore/SignalLight.swift`
- Modify: `Tests/OpenIslandCoreTests/SignalLightTests.swift`

**Interfaces:**
- Produces: `SignalLightControlCommand.pinTest(pin:on:)`, `.setPin(color:pin:)`, `.setName(_:)`, `.getConfig`, `.brightness(percent:)`, `.off` — all `String`, consumed by Task 8, 9, 11, 12. `SignalLightDeviceConfig { pins: [SignalLightColor: Int], name: String }` and `SignalLightConfigDecoder.decode(_ line: String) -> SignalLightDeviceConfig?`, consumed by Task 8.

- [ ] **Step 1: Append the new types to `SignalLight.swift`**

At the end of `Sources/OpenIslandCore/SignalLight.swift`, after the closing brace of `SignalLightCommandEncoder`, add:

```swift

/// Fire-and-forget maintenance commands sent to the signal light outside the
/// bucket-effect/`EFFECT:` protocol — pin calibration, renaming, brightness,
/// and the light switch. See `signal-light/led_esp32c3/led_esp32c3.ino`.
public enum SignalLightControlCommand {
    public static func pinTest(pin: Int, on: Bool) -> String {
        "PINTEST:\(pin):\(on ? 1 : 0)"
    }

    public static func setPin(color: SignalLightColor, pin: Int) -> String {
        "SETPIN:\(color.commandLetter):\(pin)"
    }

    public static func setName(_ name: String) -> String {
        "SETNAME:\(name)"
    }

    public static let getConfig = "GETCONFIG"

    public static func brightness(percent: Int) -> String {
        "BRIGHTNESS:\(percent)"
    }

    public static let off = "OFF"
}

/// The device's current pin mapping and BLE name, as reported by `GETCONFIG`.
public struct SignalLightDeviceConfig: Equatable, Sendable {
    public var pins: [SignalLightColor: Int]
    public var name: String

    public init(pins: [SignalLightColor: Int], name: String) {
        self.pins = pins
        self.name = name
    }
}

/// Parses the firmware's `CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2` status reply
/// (see `sendConfigStatus` in `led_esp32c3.ino`).
public enum SignalLightConfigDecoder {
    public static func decode(_ line: String) -> SignalLightDeviceConfig? {
        guard line.hasPrefix("CONFIG:") else {
            return nil
        }

        var pins: [SignalLightColor: Int] = [:]
        var name: String?

        for field in line.dropFirst("CONFIG:".count).split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])

            switch key {
            case "R": if let pin = Int(value) { pins[.red] = pin }
            case "Y": if let pin = Int(value) { pins[.yellow] = pin }
            case "G": if let pin = Int(value) { pins[.green] = pin }
            case "NAME": name = value
            default: break
            }
        }

        guard pins.count == 3, let name else {
            return nil
        }
        return SignalLightDeviceConfig(pins: pins, name: name)
    }
}
```

- [ ] **Step 2: Append tests to `SignalLightTests.swift`**

At the end of `Tests/OpenIslandCoreTests/SignalLightTests.swift`, add:

```swift

struct SignalLightControlCommandTests {
    @Test
    func encodesPinTestOn() {
        #expect(SignalLightControlCommand.pinTest(pin: 10, on: true) == "PINTEST:10:1")
    }

    @Test
    func encodesPinTestOff() {
        #expect(SignalLightControlCommand.pinTest(pin: 10, on: false) == "PINTEST:10:0")
    }

    @Test
    func encodesSetPin() {
        #expect(SignalLightControlCommand.setPin(color: .red, pin: 5) == "SETPIN:R:5")
    }

    @Test
    func encodesSetName() {
        #expect(SignalLightControlCommand.setName("MyOffice") == "SETNAME:MyOffice")
    }

    @Test
    func encodesBrightness() {
        #expect(SignalLightControlCommand.brightness(percent: 42) == "BRIGHTNESS:42")
    }

    @Test
    func exposesGetConfigAndOffAsFixedStrings() {
        #expect(SignalLightControlCommand.getConfig == "GETCONFIG")
        #expect(SignalLightControlCommand.off == "OFF")
    }
}

struct SignalLightConfigDecoderTests {
    @Test
    func decodesAWellFormedConfigLine() {
        let config = SignalLightConfigDecoder.decode("CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2")
        #expect(config == SignalLightDeviceConfig(pins: [.red: 5, .yellow: 6, .green: 7], name: "WG-A1B2"))
    }

    @Test
    func decodesRegardlessOfFieldOrder() {
        let config = SignalLightConfigDecoder.decode("CONFIG:NAME=WG-A1B2,G=7,R=5,Y=6")
        #expect(config == SignalLightDeviceConfig(pins: [.red: 5, .yellow: 6, .green: 7], name: "WG-A1B2"))
    }

    @Test
    func rejectsMissingPrefix() {
        #expect(SignalLightConfigDecoder.decode("R=5,Y=6,G=7,NAME=WG-A1B2") == nil)
    }

    @Test
    func rejectsMissingFields() {
        #expect(SignalLightConfigDecoder.decode("CONFIG:R=5,Y=6,NAME=WG-A1B2") == nil)
    }

    @Test
    func rejectsUnrelatedStatusText() {
        #expect(SignalLightConfigDecoder.decode("SETPIN ok: R=5") == nil)
    }
}
```

- [ ] **Step 3: Run the tests**

```bash
swift test --filter SignalLightControlCommandTests --filter SignalLightConfigDecoderTests
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenIslandCore/SignalLight.swift Tests/OpenIslandCoreTests/SignalLightTests.swift
git commit -m "feat: add signal light raw control commands and config decoder"
```

---

### Task 7: Core — `SignalLightCalibrationWizard` pure reducer

**Files:**
- Create: `Sources/OpenIslandCore/SignalLightCalibrationWizard.swift`
- Create: `Tests/OpenIslandCoreTests/SignalLightCalibrationWizardTests.swift`

**Interfaces:**
- Produces (consumed by Task 12): `SignalLightWizardObservation { .red, .yellow, .green, .nothing }`; `SignalLightCalibrationWizard(candidatePins: [Int])` with `.defaultCandidatePins` (static), `.currentPin: Int?`, `.unresolvedColors: [SignalLightColor]`, `.mapping: [SignalLightColor: Int]`, `.isFinished: Bool`, `mutating func recordObservation(_:)`, `mutating func reset()`.

- [ ] **Step 1: Write the full file**

Create `Sources/OpenIslandCore/SignalLightCalibrationWizard.swift`:

```swift
import Foundation

/// What the user reports seeing after a candidate pin was lit during the
/// wiring-calibration wizard.
public enum SignalLightWizardObservation: Sendable {
    case red
    case yellow
    case green
    case nothing
}

/// Drives the "which physical GPIO is actually red/yellow/green" wizard as a
/// pure state machine: given a candidate pin list and a stream of user
/// observations, produces the pin mapping to send via `SETPIN`. Has no BLE
/// dependency — `SignalLightSettingsPane` drives the actual `PINTEST` writes
/// and feeds answers back in.
public struct SignalLightCalibrationWizard: Sendable, Equatable {
    /// ESP32-C3 Super Mini safe GPIO pins, matching the firmware's
    /// `SAFE_GPIO_PINS` allow-list in `config.h`.
    public static let defaultCandidatePins = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 21]

    public let candidatePins: [Int]
    public private(set) var currentIndex: Int
    public private(set) var mapping: [SignalLightColor: Int]
    public private(set) var isFinished: Bool

    public init(candidatePins: [Int]) {
        precondition(!candidatePins.isEmpty, "Calibration wizard needs at least one candidate pin")
        self.candidatePins = candidatePins
        self.currentIndex = 0
        self.mapping = [:]
        self.isFinished = false
    }

    /// The pin the wizard is currently asking the user about, or `nil` once finished.
    public var currentPin: Int? {
        guard !isFinished, currentIndex < candidatePins.count else {
            return nil
        }
        return candidatePins[currentIndex]
    }

    /// Colors not yet matched to a pin.
    public var unresolvedColors: [SignalLightColor] {
        SignalLightColor.allCases.filter { mapping[$0] == nil }
    }

    /// Records the user's answer for `currentPin` and advances to the next
    /// candidate. No-ops once the wizard has already finished.
    public mutating func recordObservation(_ observation: SignalLightWizardObservation) {
        guard let pin = currentPin else {
            return
        }

        switch observation {
        case .red where mapping[.red] == nil:
            mapping[.red] = pin
        case .yellow where mapping[.yellow] == nil:
            mapping[.yellow] = pin
        case .green where mapping[.green] == nil:
            mapping[.green] = pin
        default:
            break
        }

        currentIndex += 1
        if unresolvedColors.isEmpty || currentIndex >= candidatePins.count {
            isFinished = true
        }
    }

    /// Resets to the beginning, discarding all recorded answers ("redo").
    public mutating func reset() {
        currentIndex = 0
        mapping = [:]
        isFinished = false
    }
}
```

- [ ] **Step 2: Write the full test file**

Create `Tests/OpenIslandCoreTests/SignalLightCalibrationWizardTests.swift`:

```swift
import Foundation
import Testing
@testable import OpenIslandCore

struct SignalLightCalibrationWizardTests {
    @Test
    func startsOnTheFirstCandidatePin() {
        let wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3])
        #expect(wizard.currentPin == 1)
        #expect(wizard.isFinished == false)
        #expect(wizard.unresolvedColors == [.red, .yellow, .green])
    }

    @Test
    func finishesAsSoonAsAllThreeColorsAreIdentified() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3, 4, 5])
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)
        wizard.recordObservation(.green)

        #expect(wizard.isFinished)
        #expect(wizard.mapping == [.red: 1, .yellow: 2, .green: 3])
        #expect(wizard.unresolvedColors.isEmpty)
    }

    @Test
    func skipsPinsReportedAsNothing() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3, 4])
        wizard.recordObservation(.nothing)
        wizard.recordObservation(.red)

        #expect(wizard.mapping == [.red: 2])
        #expect(wizard.currentPin == 3)
    }

    @Test
    func finishesWithUnresolvedColorsWhenCandidatesRunOut() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2])
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)

        #expect(wizard.isFinished)
        #expect(wizard.mapping == [.red: 1, .yellow: 2])
        #expect(wizard.unresolvedColors == [.green])
    }

    @Test
    func ignoresARepeatedAnswerForAnAlreadyResolvedColor() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3, 4])
        wizard.recordObservation(.red)
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)
        wizard.recordObservation(.green)

        #expect(wizard.mapping == [.red: 1, .yellow: 3, .green: 4])
    }

    @Test
    func resetDiscardsAllRecordedAnswers() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3])
        wizard.recordObservation(.red)
        wizard.reset()

        #expect(wizard.currentPin == 1)
        #expect(wizard.mapping.isEmpty)
        #expect(wizard.isFinished == false)
    }

    @Test
    func doesNothingOnceFinished() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3])
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)
        wizard.recordObservation(.green)
        let finishedMapping = wizard.mapping

        wizard.recordObservation(.red)

        #expect(wizard.mapping == finishedMapping)
    }
}
```

- [ ] **Step 3: Run the tests**

```bash
swift test --filter SignalLightCalibrationWizardTests
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenIslandCore/SignalLightCalibrationWizard.swift Tests/OpenIslandCoreTests/SignalLightCalibrationWizardTests.swift
git commit -m "feat: add SignalLightCalibrationWizard pure state machine"
```

---

### Task 8: App — `SignalLightCoordinator` raw sends, calibration/switch state, resync

**Files:**
- Modify: `Sources/OpenIslandApp/SignalLightCoordinator.swift`

**Interfaces:**
- Consumes: `SignalLightControlCommand`, `SignalLightDeviceConfig`, `SignalLightConfigDecoder` from Task 6.
- Produces (consumed by Task 9, 11, 12): `coordinator.sendRaw(_ command: String)`, `coordinator.isCalibrating: Bool`, `coordinator.isLightSwitchedOn: Bool`, `coordinator.currentBrightnessProvider: (() -> Int?)?`, `coordinator.lastDeviceConfig: SignalLightDeviceConfig?`, `coordinator.lastStatusMessage: String?`.
- This reuses the existing `otaControlCharacteristicUUID` / discovery / notify-subscription already added by the (already-merged) OTA feature — no new characteristic or discovery call is added here.

- [ ] **Step 1: Add the new stored properties**

Replace:

```swift
    private(set) var status: SignalLightConnectionStatus = .disconnected
    private(set) var discoveredDevices: [SignalLightDiscoveredDevice] = []
    private(set) var firmwareVersion: String?
    let firmwareUpdater = SignalLightFirmwareUpdater()

    /// Supplies the effect that should currently be showing. Called right
    /// after a (re)connection completes so the light can resync to current
    /// reality instead of being left on whatever it displayed before a drop.
    var currentEffectProvider: (() -> SignalLightEffect?)?

    @ObservationIgnored private var centralManager: CBCentralManager?
```

with:

```swift
    private(set) var status: SignalLightConnectionStatus = .disconnected
    private(set) var discoveredDevices: [SignalLightDiscoveredDevice] = []
    private(set) var firmwareVersion: String?
    private(set) var lastDeviceConfig: SignalLightDeviceConfig?
    private(set) var lastStatusMessage: String?
    let firmwareUpdater = SignalLightFirmwareUpdater()

    /// Supplies the effect that should currently be showing. Called right
    /// after a (re)connection completes so the light can resync to current
    /// reality instead of being left on whatever it displayed before a drop.
    var currentEffectProvider: (() -> SignalLightEffect?)?

    /// Supplies the brightness percent (0-100) that should currently be
    /// applied. Resynced alongside the effect on every (re)connection.
    var currentBrightnessProvider: (() -> Int?)?

    /// While `true`, `AppModel` suppresses its automatic session-driven
    /// effect push so a live session transition can't interrupt an
    /// in-progress `PINTEST` wiring-calibration sequence.
    var isCalibrating = false

    /// Mirrors `AppModel.signalLightEnabled`. Governs whether a (re)connect
    /// resyncs to the current effect or explicitly sends `OFF`.
    var isLightSwitchedOn = true

    @ObservationIgnored private var centralManager: CBCentralManager?
```

- [ ] **Step 2: Add `sendRaw`**

Replace:

```swift
    func send(_ effect: SignalLightEffect) {
        guard let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic,
              peripheral.state == .connected else {
            return
        }
        let command = SignalLightCommandEncoder.encode(effect)
        peripheral.writeValue(Data(command.utf8), for: characteristic, type: .withResponse)
    }

    func beginFirmwareUpdate(fileURL: URL) {
```

with:

```swift
    func send(_ effect: SignalLightEffect) {
        guard let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic,
              peripheral.state == .connected else {
            return
        }
        let command = SignalLightCommandEncoder.encode(effect)
        peripheral.writeValue(Data(command.utf8), for: characteristic, type: .withResponse)
    }

    /// Sends a raw text command (`PINTEST:`/`SETPIN:`/`SETNAME:`/`GETCONFIG`/
    /// `BRIGHTNESS:`/`OFF`) — silently no-ops if not connected, same
    /// fail-open behavior as `send(_:)`.
    func sendRaw(_ command: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic,
              peripheral.state == .connected else {
            return
        }
        peripheral.writeValue(Data(command.utf8), for: characteristic, type: .withResponse)
    }

    func beginFirmwareUpdate(fileURL: URL) {
```

- [ ] **Step 3: Make the post-connect resync respect the light switch, resync brightness, and refresh config**

Replace:

```swift
            guard commandCharacteristic != nil else {
                return
            }
            status = .connected(name: peripheral.name ?? "Signal Light")
            firmwareUpdater.acknowledgeSuccess()
            if let effect = currentEffectProvider?() {
                send(effect)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated {
            firmwareUpdater.handleWriteResponse(for: characteristic, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard error == nil, let value = characteristic.value, let text = String(data: value, encoding: .utf8) else {
                return
            }

            if characteristic.uuid == Self.infoCharacteristicUUID {
                firmwareVersion = text
            } else if characteristic.uuid == Self.otaControlCharacteristicUUID {
                firmwareUpdater.handleControlStatusUpdate(text)
            }
        }
    }
}
```

with:

```swift
            guard commandCharacteristic != nil else {
                return
            }
            status = .connected(name: peripheral.name ?? "Signal Light")
            firmwareUpdater.acknowledgeSuccess()

            if isLightSwitchedOn {
                if let effect = currentEffectProvider?() {
                    send(effect)
                }
            } else {
                sendRaw(SignalLightControlCommand.off)
            }

            if let brightness = currentBrightnessProvider?() {
                sendRaw(SignalLightControlCommand.brightness(percent: brightness))
            }

            sendRaw(SignalLightControlCommand.getConfig)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated {
            firmwareUpdater.handleWriteResponse(for: characteristic, error: error)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard error == nil, let value = characteristic.value, let text = String(data: value, encoding: .utf8) else {
                return
            }

            if characteristic.uuid == Self.infoCharacteristicUUID {
                firmwareVersion = text
            } else if characteristic.uuid == Self.otaControlCharacteristicUUID {
                if let config = SignalLightConfigDecoder.decode(text) {
                    lastDeviceConfig = config
                } else {
                    lastStatusMessage = text
                    firmwareUpdater.handleControlStatusUpdate(text)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Build**

```bash
swift build
```
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandApp/SignalLightCoordinator.swift
git commit -m "feat: add raw command sending, calibration/switch state, and config readback to SignalLightCoordinator"
```

---

### Task 9: App — `AppModel` brightness/switch preferences and gating

**Files:**
- Modify: `Sources/OpenIslandApp/AppModel.swift`

**Interfaces:**
- Consumes: `SignalLightControlCommand` from Task 6; `signalLight.sendRaw`/`isCalibrating`/`isLightSwitchedOn`/`currentBrightnessProvider` from Task 8.
- Produces (consumed by Task 11, 12): `model.signalLightBrightness: Int`, `model.signalLightEnabled: Bool`.

- [ ] **Step 1: Add the new UserDefaults keys**

Replace:

```swift
    private static let appearanceProfileSettingsDefaultsKey = "appearance.island.v8.settingsProfile"
    private static let signalLightEffectsDefaultsKey = "signalLight.effects"
```

with:

```swift
    private static let appearanceProfileSettingsDefaultsKey = "appearance.island.v8.settingsProfile"
    private static let signalLightEffectsDefaultsKey = "signalLight.effects"
    private static let signalLightBrightnessDefaultsKey = "signalLight.brightness"
    private static let signalLightEnabledDefaultsKey = "signalLight.enabled"
```

- [ ] **Step 2: Gate the automatic bucket-effect push on the light switch and calibration state**

Replace:

```swift
    var state = SessionState() {
        didSet {
            _cachedSessionBuckets = nil
            pruneAgentsGridObservationTicketsIfNeeded()
            bridgeServer.updateStateSnapshot(state)

            let bucket = SignalLightBucketResolver.resolve(state)
            if bucket != lastSentSignalLightBucket {
                lastSentSignalLightBucket = bucket
                signalLight.send(signalLightEffects[bucket] ?? .defaultEffect(for: bucket))
            }
        }
    }
```

with:

```swift
    var state = SessionState() {
        didSet {
            _cachedSessionBuckets = nil
            pruneAgentsGridObservationTicketsIfNeeded()
            bridgeServer.updateStateSnapshot(state)

            let bucket = SignalLightBucketResolver.resolve(state)
            if bucket != lastSentSignalLightBucket {
                lastSentSignalLightBucket = bucket
                if signalLightEnabled && !signalLight.isCalibrating {
                    signalLight.send(resolvedSignalLightEffect())
                }
            }
        }
    }
```

- [ ] **Step 3: Add the `signalLightBrightness`/`signalLightEnabled` properties**

Replace:

```swift
    var signalLightEffects: [SignalLightBucket: SignalLightEffect] = AppModel.loadSignalLightEffects() {
        didSet {
            guard let data = try? JSONEncoder().encode(signalLightEffects) else {
                return
            }
            UserDefaults.standard.set(data, forKey: Self.signalLightEffectsDefaultsKey)
        }
    }
```

with:

```swift
    var signalLightEffects: [SignalLightBucket: SignalLightEffect] = AppModel.loadSignalLightEffects() {
        didSet {
            guard let data = try? JSONEncoder().encode(signalLightEffects) else {
                return
            }
            UserDefaults.standard.set(data, forKey: Self.signalLightEffectsDefaultsKey)
        }
    }

    var signalLightBrightness: Int = AppModel.loadSignalLightBrightness() {
        didSet {
            guard signalLightBrightness != oldValue else { return }
            UserDefaults.standard.set(signalLightBrightness, forKey: Self.signalLightBrightnessDefaultsKey)
            signalLight.sendRaw(SignalLightControlCommand.brightness(percent: signalLightBrightness))
        }
    }

    var signalLightEnabled: Bool = AppModel.loadSignalLightEnabled() {
        didSet {
            guard signalLightEnabled != oldValue else { return }
            UserDefaults.standard.set(signalLightEnabled, forKey: Self.signalLightEnabledDefaultsKey)
            signalLight.isLightSwitchedOn = signalLightEnabled
            if signalLightEnabled {
                signalLight.send(resolvedSignalLightEffect())
            } else {
                signalLight.sendRaw(SignalLightControlCommand.off)
            }
        }
    }
```

- [ ] **Step 4: Add the loaders and the shared effect-resolution helper**

Replace:

```swift
    private static func loadSignalLightEffects() -> [SignalLightBucket: SignalLightEffect] {
        if let data = UserDefaults.standard.data(forKey: signalLightEffectsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SignalLightBucket: SignalLightEffect].self, from: data) {
            return decoded
        }
        return Dictionary(uniqueKeysWithValues: SignalLightBucket.allCases.map { ($0, .defaultEffect(for: $0)) })
    }
```

with:

```swift
    private static func loadSignalLightEffects() -> [SignalLightBucket: SignalLightEffect] {
        if let data = UserDefaults.standard.data(forKey: signalLightEffectsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SignalLightBucket: SignalLightEffect].self, from: data) {
            return decoded
        }
        return Dictionary(uniqueKeysWithValues: SignalLightBucket.allCases.map { ($0, .defaultEffect(for: $0)) })
    }

    private static func loadSignalLightBrightness() -> Int {
        guard UserDefaults.standard.object(forKey: signalLightBrightnessDefaultsKey) != nil else {
            return 100
        }
        return UserDefaults.standard.integer(forKey: signalLightBrightnessDefaultsKey)
    }

    private static func loadSignalLightEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: signalLightEnabledDefaultsKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: signalLightEnabledDefaultsKey)
    }

    private func resolvedSignalLightEffect() -> SignalLightEffect {
        let bucket = SignalLightBucketResolver.resolve(state)
        return signalLightEffects[bucket] ?? .defaultEffect(for: bucket)
    }
```

- [ ] **Step 5: Wire up the coordinator's brightness provider and initial switch state in `init()`**

Replace:

```swift
        signalLight.currentEffectProvider = { [weak self] in
            guard let self else { return nil }
            let bucket = SignalLightBucketResolver.resolve(self.state)
            return self.signalLightEffects[bucket] ?? .defaultEffect(for: bucket)
        }
```

with:

```swift
        signalLight.currentEffectProvider = { [weak self] in
            self?.resolvedSignalLightEffect()
        }
        signalLight.currentBrightnessProvider = { [weak self] in
            self?.signalLightBrightness
        }
        signalLight.isLightSwitchedOn = signalLightEnabled
```

- [ ] **Step 6: Build**

```bash
swift build
```
Expected: builds with no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenIslandApp/AppModel.swift
git commit -m "feat: add signal light brightness and light-switch preferences to AppModel"
```

---

### Task 10: Localization strings

**Files:**
- Modify: `Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hant.lproj/Localizable.strings`

**Interfaces:**
- Produces: the `settings.signalLight.{lightSwitch,rename*,brightness,calibrate*,red,yellow,green}` keys below, consumed by Task 11/12. Reuses the existing `settings.signalLight.red/yellow/green` and `settings.general.cancel` keys — no duplicates added for those.

- [ ] **Step 1: Append to `en.lproj/Localizable.strings`**

After the existing `"settings.signalLight.firmwareFailedReassurance" = "The signal light is still running its previous firmware — you can try again.";` line, add:

```
"settings.signalLight.lightSwitch" = "Light Switch";
"settings.signalLight.renamePlaceholder" = "New name";
"settings.signalLight.rename" = "Rename";
"settings.signalLight.renameReconnecting" = "Device is restarting and reconnecting…";
"settings.signalLight.brightness" = "Brightness";
"settings.signalLight.calibrateWiring" = "Calibrate Wiring";
"settings.signalLight.calibrateTitle" = "Wiring Calibration";
"settings.signalLight.calibrateAsking" = "Which color just lit up?";
"settings.signalLight.calibrateNothing" = "None";
"settings.signalLight.calibrateSucceeded" = "Calibration complete — all three colors identified.";
"settings.signalLight.calibrateNotFoundPrefix" = "Couldn't identify: ";
"settings.signalLight.calibrateRedo" = "Start Over";
"settings.signalLight.calibrateDone" = "Done";
```

- [ ] **Step 2: Append to `zh-Hans.lproj/Localizable.strings`**

After the existing `"settings.signalLight.firmwareFailedReassurance" = "信号灯仍在运行之前的固件，可以重试。";` line, add:

```
"settings.signalLight.lightSwitch" = "灯光开关";
"settings.signalLight.renamePlaceholder" = "新名称";
"settings.signalLight.rename" = "重命名";
"settings.signalLight.renameReconnecting" = "设备正在重启并重新连接…";
"settings.signalLight.brightness" = "亮度";
"settings.signalLight.calibrateWiring" = "校准接线";
"settings.signalLight.calibrateTitle" = "接线校准";
"settings.signalLight.calibrateAsking" = "刚才亮起的是哪个颜色？";
"settings.signalLight.calibrateNothing" = "都没有";
"settings.signalLight.calibrateSucceeded" = "校准完成，三种颜色已全部识别。";
"settings.signalLight.calibrateNotFoundPrefix" = "未能识别：";
"settings.signalLight.calibrateRedo" = "重新开始";
"settings.signalLight.calibrateDone" = "完成";
```

- [ ] **Step 3: Append to `zh-Hant.lproj/Localizable.strings`**

After the existing `"settings.signalLight.firmwareFailedReassurance" = "信號燈仍在執行先前的韌體，可以重試。";` line, add:

```
"settings.signalLight.lightSwitch" = "燈光開關";
"settings.signalLight.renamePlaceholder" = "新名稱";
"settings.signalLight.rename" = "重新命名";
"settings.signalLight.renameReconnecting" = "裝置正在重新啟動並重新連線…";
"settings.signalLight.brightness" = "亮度";
"settings.signalLight.calibrateWiring" = "校準接線";
"settings.signalLight.calibrateTitle" = "接線校準";
"settings.signalLight.calibrateAsking" = "剛才亮起的是哪個顏色？";
"settings.signalLight.calibrateNothing" = "都沒有";
"settings.signalLight.calibrateSucceeded" = "校準完成，三種顏色已全部識別。";
"settings.signalLight.calibrateNotFoundPrefix" = "未能識別：";
"settings.signalLight.calibrateRedo" = "重新開始";
"settings.signalLight.calibrateDone" = "完成";
```

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenIslandApp/Resources/*/Localizable.strings
git commit -m "feat: localize light switch, rename, brightness, and calibration strings"
```

---

### Task 11: App — Settings UI: light switch, rename, brightness slider

**Files:**
- Modify: `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`

**Interfaces:**
- Consumes: `model.signalLightEnabled`/`model.signalLightBrightness` (Task 9), `model.signalLight.sendRaw`/`SignalLightControlCommand.setName` (Task 6, 8), localization keys from Task 10.

- [ ] **Step 1: Add new `@State`, the brightness section in `body`, and a status-change hook to clear the rename notice**

Replace:

```swift
struct SignalLightSettingsPane: View {
    var model: AppModel

    @State private var selectedFirmwareURL: URL?
    @State private var isShowingFlashConfirmation = false

    private var lang: LanguageManager { model.lang }

    private var isTransferring: Bool {
        switch model.signalLight.firmwareUpdater.state {
        case .transferring, .finishing:
            true
        default:
            false
        }
    }

    var body: some View {
        Form {
            deviceSection
            modesSection
            firmwareSection
        }
        .formStyle(.grouped)
        .navigationTitle(lang.t("settings.tab.signalLight"))
    }
```

with:

```swift
struct SignalLightSettingsPane: View {
    var model: AppModel

    @State private var selectedFirmwareURL: URL?
    @State private var isShowingFlashConfirmation = false
    @State private var renameText = ""
    @State private var isShowingRenameReconnectNotice = false

    private var lang: LanguageManager { model.lang }

    private var isTransferring: Bool {
        switch model.signalLight.firmwareUpdater.state {
        case .transferring, .finishing:
            true
        default:
            false
        }
    }

    var body: some View {
        Form {
            deviceSection
            brightnessSection
            modesSection
            firmwareSection
        }
        .formStyle(.grouped)
        .navigationTitle(lang.t("settings.tab.signalLight"))
        .onChange(of: model.signalLight.status) { _, newStatus in
            if case .connected = newStatus {
                isShowingRenameReconnectNotice = false
            }
        }
    }
```

- [ ] **Step 2: Add the light switch toggle and rename row to `deviceSection`**

Replace:

```swift
    @ViewBuilder
    private var deviceSection: some View {
        Section(lang.t("settings.signalLight.device")) {
            HStack {
                Label(lang.t("settings.signalLight.status"), systemImage: "light.beacon.max.fill")
                Spacer()
                statusBadge
            }

            switch model.signalLight.status {
            case .unauthorized:
                unauthorizedBanner
            case .poweredOff:
                Text(lang.t("settings.signalLight.turnOnBluetooth"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connected:
                Button(lang.t("settings.signalLight.disconnect"), role: .destructive) {
                    model.signalLight.disconnect()
                }
                .disabled(isTransferring)
            default:
                discoveredDevicesList
                Button(lang.t("settings.signalLight.scan")) {
                    model.signalLight.startScan()
                }
            }
        }
    }
```

with:

```swift
    @ViewBuilder
    private var deviceSection: some View {
        Section(lang.t("settings.signalLight.device")) {
            HStack {
                Label(lang.t("settings.signalLight.status"), systemImage: "light.beacon.max.fill")
                Spacer()
                statusBadge
            }

            Toggle(lang.t("settings.signalLight.lightSwitch"), isOn: $model.signalLightEnabled)

            switch model.signalLight.status {
            case .unauthorized:
                unauthorizedBanner
            case .poweredOff:
                Text(lang.t("settings.signalLight.turnOnBluetooth"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connected:
                renameRow
                Button(lang.t("settings.signalLight.disconnect"), role: .destructive) {
                    model.signalLight.disconnect()
                }
                .disabled(isTransferring)
            default:
                discoveredDevicesList
                Button(lang.t("settings.signalLight.scan")) {
                    model.signalLight.startScan()
                }
            }
        }
    }

    @ViewBuilder
    private var renameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(lang.t("settings.signalLight.renamePlaceholder"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                Button(lang.t("settings.signalLight.rename")) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    model.signalLight.sendRaw(SignalLightControlCommand.setName(trimmed))
                    isShowingRenameReconnectNotice = true
                    renameText = ""
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isShowingRenameReconnectNotice {
                Text(lang.t("settings.signalLight.renameReconnecting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var brightnessSection: some View {
        Section(lang.t("settings.signalLight.brightness")) {
            Slider(
                value: Binding(
                    get: { Double(model.signalLightBrightness) },
                    set: { model.signalLightBrightness = Int($0.rounded()) }
                ),
                in: 0...100
            )
            Text("\(model.signalLightBrightness)%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
```

- [ ] **Step 3: Build**

```bash
swift build
```
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift
git commit -m "feat: add light switch, rename, and brightness controls to Signal Light settings"
```

---

### Task 12: App — Settings UI: wiring calibration wizard

**Files:**
- Modify: `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`

**Interfaces:**
- Consumes: `SignalLightCalibrationWizard`/`SignalLightWizardObservation` (Task 7), `SignalLightControlCommand.pinTest/setPin` (Task 6), `model.signalLight.sendRaw/send/isCalibrating` (Task 8), `SignalLightBucketResolver` (existing Core type).

- [ ] **Step 1: Add wizard `@State` and the sheet presentation**

Replace:

```swift
    @State private var selectedFirmwareURL: URL?
    @State private var isShowingFlashConfirmation = false
    @State private var renameText = ""
    @State private var isShowingRenameReconnectNotice = false
```

with:

```swift
    @State private var selectedFirmwareURL: URL?
    @State private var isShowingFlashConfirmation = false
    @State private var renameText = ""
    @State private var isShowingRenameReconnectNotice = false
    @State private var wizard: SignalLightCalibrationWizard?
```

Then replace:

```swift
        .onChange(of: model.signalLight.status) { _, newStatus in
            if case .connected = newStatus {
                isShowingRenameReconnectNotice = false
            }
        }
    }
```

with:

```swift
        .onChange(of: model.signalLight.status) { _, newStatus in
            if case .connected = newStatus {
                isShowingRenameReconnectNotice = false
            }
        }
        .sheet(isPresented: Binding(
            get: { wizard != nil },
            set: { isPresented in if !isPresented { cancelCalibration() } }
        )) {
            if let wizard {
                calibrationWizardView(wizard)
            }
        }
    }
```

- [ ] **Step 2: Add the "Calibrate Wiring" button to `deviceSection`**

Replace:

```swift
            case .connected:
                renameRow
                Button(lang.t("settings.signalLight.disconnect"), role: .destructive) {
                    model.signalLight.disconnect()
                }
                .disabled(isTransferring)
```

with:

```swift
            case .connected:
                renameRow
                Button(lang.t("settings.signalLight.calibrateWiring")) {
                    beginCalibration()
                }
                Button(lang.t("settings.signalLight.disconnect"), role: .destructive) {
                    model.signalLight.disconnect()
                }
                .disabled(isTransferring)
```

- [ ] **Step 3: Add the wizard-driving functions and sheet view at the end of the struct**

Replace:

```swift
    private func formattedByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
```

with:

```swift
    private func formattedByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Wiring Calibration

    private func beginCalibration() {
        var newWizard = SignalLightCalibrationWizard(candidatePins: SignalLightCalibrationWizard.defaultCandidatePins)
        model.signalLight.isCalibrating = true
        if let pin = newWizard.currentPin {
            model.signalLight.sendRaw(SignalLightControlCommand.pinTest(pin: pin, on: true))
        }
        wizard = newWizard
    }

    private func recordCalibrationObservation(_ observation: SignalLightWizardObservation) {
        guard var current = wizard else { return }
        if let pin = current.currentPin {
            model.signalLight.sendRaw(SignalLightControlCommand.pinTest(pin: pin, on: false))
        }
        current.recordObservation(observation)
        wizard = current

        if current.isFinished {
            applyCalibrationResult(current)
        } else if let nextPin = current.currentPin {
            model.signalLight.sendRaw(SignalLightControlCommand.pinTest(pin: nextPin, on: true))
        }
    }

    private func applyCalibrationResult(_ finished: SignalLightCalibrationWizard) {
        for (color, pin) in finished.mapping {
            model.signalLight.sendRaw(SignalLightControlCommand.setPin(color: color, pin: pin))
        }
        if finished.unresolvedColors.isEmpty {
            model.signalLight.send(SignalLightEffect(type: .cycle, colors: [.red, .yellow, .green], intervalMs: 200))
        }
    }

    private func closeCalibration() {
        model.signalLight.isCalibrating = false
        wizard = nil
        let bucket = SignalLightBucketResolver.resolve(model.state)
        model.signalLight.send(model.signalLightEffects[bucket] ?? .defaultEffect(for: bucket))
    }

    private func cancelCalibration() {
        model.signalLight.isCalibrating = false
        wizard = nil
    }

    @ViewBuilder
    private func calibrationWizardView(_ wizard: SignalLightCalibrationWizard) -> some View {
        VStack(spacing: 16) {
            Text(lang.t("settings.signalLight.calibrateTitle"))
                .font(.headline)

            if let pin = wizard.currentPin {
                Text(lang.t("settings.signalLight.calibrateAsking"))
                    .font(.subheadline)
                Text("GPIO \(pin)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(lang.t("settings.signalLight.red")) { recordCalibrationObservation(.red) }
                    Button(lang.t("settings.signalLight.yellow")) { recordCalibrationObservation(.yellow) }
                    Button(lang.t("settings.signalLight.green")) { recordCalibrationObservation(.green) }
                    Button(lang.t("settings.signalLight.calibrateNothing")) { recordCalibrationObservation(.nothing) }
                }

                Button(lang.t("settings.general.cancel"), role: .cancel) {
                    cancelCalibration()
                }
            } else {
                if wizard.unresolvedColors.isEmpty {
                    Text(lang.t("settings.signalLight.calibrateSucceeded"))
                        .foregroundStyle(.green)
                } else {
                    Text(lang.t("settings.signalLight.calibrateNotFoundPrefix") + wizard.unresolvedColors.map(colorName).joined(separator: ", "))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button(lang.t("settings.signalLight.calibrateRedo")) {
                        beginCalibration()
                    }
                    Button(lang.t("settings.signalLight.calibrateDone")) {
                        closeCalibration()
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }

    private func colorName(_ color: SignalLightColor) -> String {
        switch color {
        case .red: lang.t("settings.signalLight.red")
        case .yellow: lang.t("settings.signalLight.yellow")
        case .green: lang.t("settings.signalLight.green")
        }
    }
}
```

- [ ] **Step 4: Build**

```bash
swift build
```
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift
git commit -m "feat: add wiring calibration wizard to Signal Light settings"
```

---

### Task 13: End-to-end manual verification with a physical board

This task has no code changes — it's the manual verification pass called for in the design spec's testing plan, and requires a physical ESP32-C3 signal-light board, a USB cable for the baseline flash, and a spare LED/wire for deliberately testing a miswiring scenario.

**Files:** none (verification only)

- [ ] **Step 1: Flash the updated firmware via USB**

In Arduino IDE, open `signal-light/led_esp32c3/led_esp32c3.ino`, compile, and flash to the board over USB as usual.

- [ ] **Step 2: Confirm the factory-unique BLE name**

```bash
zsh scripts/launch-dev-app.sh
```
In Settings → Signal Light, scan and confirm the device shows up as `WG-XXXX` (not the old fixed `drg5`) even though it's never been renamed.

- [ ] **Step 3: Wiring calibration — deliberately miswire a spare LED**

Move one LED's wire to a GPIO outside the firmware's known 5/6/7 (e.g. GPIO 10), power-cycle the board so it boots with the wrong default mapping for that color, connect in the app, and tap "Calibrate Wiring". Step through the wizard, correctly identifying each color (including the one on the unexpected pin), and confirm:
- The confirmation cycle blink at the end shows all three colors correctly.
- Power-cycling the board again preserves the corrected mapping (NVS persistence).

- [ ] **Step 4: Wiring calibration — a color that can't be found**

Physically disconnect one LED entirely, run the wizard, answer "None" for every candidate pin, and confirm the wizard reports the missing color rather than hanging or crashing, while leaving the other two colors' mappings intact.

- [ ] **Step 5: Rename**

While connected, enter a custom name (e.g. "办公室") in the rename field and confirm: the device disconnects, restarts, and the app auto-reconnects without any manual action, and the new name is reflected in the status badge.

- [ ] **Step 6: Brightness**

While a bucket effect is actively showing (e.g. trigger `running`), drag the brightness slider from 100 down to near 0 and confirm the physical light visibly dims in real time. Power-cycle the board, reconnect, and confirm the brightness resyncs to the last-set value rather than resetting to 100%.

- [ ] **Step 7: Light switch**

Toggle the light switch off and confirm all three LEDs go dark immediately while the device stays connected (status badge still shows "Connected"). Trigger a session-state change (e.g. simulate a session moving to `running`) while off, and confirm nothing lights up. Toggle the switch back on and confirm it immediately reflects the current session state.

- [ ] **Step 8: Light switch + calibration interaction**

With the light switched off, run the wiring-calibration wizard and confirm `PINTEST` still lights LEDs during the test (this is the fix from Task 3). After finishing or cancelling the wizard, confirm the light returns to fully off rather than turning on.

- [ ] **Step 9: Cross-check with the existing OTA feature**

With everything above working, confirm the existing firmware-OTA flow (Settings → Signal Light → Firmware section) still works — flash a same-version rebuild and confirm it completes successfully. This confirms the shared `otaControlCharacteristicUUID` notify channel correctly carries both OTA status and the new `CONFIG:`/error status text without cross-talk.

No commit for this task — it's verification only. If any step surfaces a bug, fix it as a follow-up commit referencing the specific task/file it belongs to, then re-run the affected verification step.
