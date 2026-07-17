# Signal Light Active-High Polarity Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the signal-light ESP32-C3 firmware support active-high LED wiring (in addition to today's active-low-only behavior) as a runtime, persisted, immediately-applied setting, with the macOS app able to read and change it — via a Settings toggle and a wiring-calibration-wizard escape hatch.

**Architecture:** Firmware gains one new bool (`ledActiveHigh`, NVS-backed, default `false`) that drives the LEDC channels' `output_invert` flag plus two other hard-coded-polarity call sites, exposed over a new `SETPOLARITY:LOW|HIGH` command and a new `POL=` field in the existing `GETCONFIG` reply. The app's protocol layer, connection layer, and Settings UI are extended to read/write it, treating the device's NVS as the source of truth (read via `GETCONFIG`, never blindly pushed on reconnect the way brightness is).

**Tech Stack:** Arduino/ESP32 C++ (`.ino`/`config.h`, ESP-IDF `driver/ledc.h`), Swift 6.2 / SwiftUI, Swift Testing (`@Test`/`#expect`).

## Global Constraints

- **No TDD.** Per explicit user instruction: implement directly, then verify by compiling/building/running the existing (and newly-appended) test suite — do not write a failing test first. Every task below is Implement → Verify → Commit, not Red → Green → Refactor.
- **Active-low hardware must not regress.** `ledActiveHigh` defaults to `false` everywhere it's read (NVS default, decoder default, struct default). Every touched call site must be checked against its current active-low output: the boot-time forced-off level, `output_invert`, and `driveTestPin`'s on/off levels must each produce **exactly** the same electrical output as today when `ledActiveHigh == false`. This is called out explicitly in the tasks that touch these sites.
- Requires macOS 14+, Swift 6.2 (existing project floor, unchanged).
- Conventional commit messages (`feat:`, `fix:`, `docs:`, `chore:`).
- Work continues directly on the current branch (`wg`) in this primary worktree — matching the pattern already used for the preceding signal-light commits on this branch (`85570a2`, `f07c8a2`, `e077105`, `b3ac458`, `f2219ac`) and for the spec commit (`ce0c700`) earlier this session. This is **not** the `feat/<topic>`-off-`main` flow CLAUDE.md describes for ordinary feature work; `wg` is this hardware line's own long-lived working branch.
- Bilingual UI copy required: every new user-facing string needs `en`/`zh-Hans`/`zh-Hant` entries.
- Spec: `docs/superpowers/specs/2026-07-17-signal-light-active-high-polarity-design.md` — read it for the full rationale; this plan implements it task-by-task.

---

## File Structure

| File | Change |
|---|---|
| `signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.3.0.ino` | **Create** (copy of `esp32c3-1.2.2.ino`) — polarity state, `SETPOLARITY` command, `GETCONFIG` field, three polarity-aware call sites |
| `signal-light/esp32c3/esp32c3-1.3.0/config.h` | **Create** (copy of `esp32c3-1.2.2/config.h`) — `FIRMWARE_VERSION` bumped to `"1.3.0"` |
| `signal-light/esp32c3/firmware/version.json` | **Modify** — new version entry + history line |
| `Sources/OpenIslandCore/SignalLight.swift` | **Modify** — `SignalLightControlCommand.setPolarity`, `SignalLightDeviceConfig.activeHigh`, decoder `POL` parsing |
| `Tests/OpenIslandCoreTests/SignalLightTests.swift` | **Modify** — encode/decode coverage for the above |
| `Sources/OpenIslandApp/SignalLightCoordinator.swift` | **Modify** — send `GETCONFIG` on connect, clear `lastDeviceConfig` on disconnect |
| `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift` | **Modify** — polarity row, wizard escape-hatch button, supporting state/functions |
| `Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings` | **Modify** — 4 new keys |
| `Sources/OpenIslandApp/Resources/zh-Hans.lproj/Localizable.strings` | **Modify** — 4 new keys |
| `Sources/OpenIslandApp/Resources/zh-Hant.lproj/Localizable.strings` | **Modify** — 4 new keys |

---

### Task 1: Scaffold firmware version `1.3.0`

**Files:**
- Create: `signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.3.0.ino` (copied, unmodified content, from `signal-light/esp32c3/esp32c3-1.2.2/esp32c3-1.2.2.ino`)
- Create: `signal-light/esp32c3/esp32c3-1.3.0/config.h` (copied from `signal-light/esp32c3/esp32c3-1.2.2/config.h`, version bumped)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the working directory `signal-light/esp32c3/esp32c3-1.3.0/` that every later firmware task edits in place. `build-firmware.sh 1.3.0` (from `signal-light/esp32c3/`) is the compile check every firmware task below re-runs.

- [ ] **Step 1: Copy the version directory and rename the sketch file**

```bash
cd /Users/itdragons/github/open-vibe-island
cp -R signal-light/esp32c3/esp32c3-1.2.2 signal-light/esp32c3/esp32c3-1.3.0
mv signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.2.2.ino signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.3.0.ino
```

- [ ] **Step 2: Bump `FIRMWARE_VERSION` in the new `config.h`**

In `signal-light/esp32c3/esp32c3-1.3.0/config.h`, change:

```cpp
const String FIRMWARE_VERSION = "1.2.2";
```

to:

```cpp
const String FIRMWARE_VERSION = "1.3.0";
```

- [ ] **Step 3: Compile check — confirm the untouched copy still builds**

```bash
cd /Users/itdragons/github/open-vibe-island/signal-light/esp32c3
./build-firmware.sh 1.3.0
```

Expected: ends with `>>> 完成: .../firmware/esp32c3-1.3.0.bin` and a printed size/sha256 — no compile errors. This is a pure sanity check (no functional edits have been made yet); a failure here means the copy/rename itself is broken, before any polarity logic is added.

- [ ] **Step 4: Commit**

```bash
git add signal-light/esp32c3/esp32c3-1.3.0/
git commit -m "chore(esp32c3): scaffold firmware 1.3.0 from 1.2.2"
```

---

### Task 2: Firmware — polarity-aware electrical layer

**Files:**
- Modify: `signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.3.0.ino`

**Interfaces:**
- Consumes: nothing beyond the scaffold from Task 1.
- Produces: global `bool ledActiveHigh` (default `false`, loaded from NVS key `"ledActiveHigh"` during `setup()`) that Task 3's `SETPOLARITY` handler reads and writes.

This task makes the three currently-hard-coded-active-low call sites read `ledActiveHigh` instead. No new command yet — `ledActiveHigh` can only change via direct NVS edit (not exposed) until Task 3, so behavior is unchanged end-to-end after this task; it exists purely to make the compile-check meaningful before the command layer is added.

- [ ] **Step 1: Add the `ledActiveHigh` global**

In `esp32c3-1.3.0.ino`, find:

```cpp
bool lightOn = true; // 灯光总开关：OFF 命令置为 false，其余命令通常会置为 true
```

Add immediately after it:

```cpp

// LED 接线极性：false=低电平点亮（出厂默认，历史机型行为不变），true=高电平点亮。
// 通过 SETPOLARITY 命令运行时切换并持久化到 NVS，无需重新烧录固件（见 handleSetPolarityCommand）。
bool ledActiveHigh = false;
```

- [ ] **Step 2: Read `ledActiveHigh` from NVS at boot, and make the forced-off level polarity-aware**

Find this block in `setup()`:

```cpp
  brightnessPercent = prefs.getInt("brightness", 100);
  Serial.println("Pins -> R:" + String(led_red) + " Y:" + String(led_yellow) + " G:" + String(led_green));
  Serial.println("BLE name -> " + bleName);

  // 先用数字高电平把三路引脚摁灭，覆盖 configureAllLedChannels 接管前的窗口。
  // 顺序关键：先 pinMode(OUTPUT) 再 digitalWrite(HIGH)；反过来时引脚仍是 INPUT，
  // pinMode(OUTPUT) 生效瞬间会输出默认低电平（反相=满亮），造成开机满亮闪。
  pinMode(led_green, OUTPUT);
  digitalWrite(led_green, HIGH);
  pinMode(led_red, OUTPUT);
  digitalWrite(led_red, HIGH);
  pinMode(led_yellow, OUTPUT);
  digitalWrite(led_yellow, HIGH);
```

Replace with:

```cpp
  brightnessPercent = prefs.getInt("brightness", 100);
  ledActiveHigh = prefs.getBool("ledActiveHigh", false);
  Serial.println("Pins -> R:" + String(led_red) + " Y:" + String(led_yellow) + " G:" + String(led_green));
  Serial.println("BLE name -> " + bleName);
  Serial.println("Polarity -> " + String(ledActiveHigh ? "HIGH" : "LOW"));

  // 先把三路引脚摁灭，覆盖 configureAllLedChannels 接管前的窗口。熄灯电平由
  // ledActiveHigh 决定：低电平点亮（默认，未跑过 SETPOLARITY 的设备恒为此值）时熄灯电平是
  // HIGH——与改动前完全一致；高电平点亮时熄灯电平是 LOW。
  // 顺序关键：先 pinMode(OUTPUT) 再 digitalWrite；反过来时引脚仍是 INPUT，pinMode(OUTPUT)
  // 生效瞬间会输出默认低电平，若恰好是当前极性下的点亮电平，会造成开机满亮闪。
  int bootOffLevel = ledActiveHigh ? LOW : HIGH;
  pinMode(led_green, OUTPUT);
  digitalWrite(led_green, bootOffLevel);
  pinMode(led_red, OUTPUT);
  digitalWrite(led_red, bootOffLevel);
  pinMode(led_yellow, OUTPUT);
  digitalWrite(led_yellow, bootOffLevel);
```

**Active-low regression check for this step:** with `ledActiveHigh == false` (the NVS default for every existing device), `bootOffLevel` evaluates to `HIGH` — byte-for-byte the same value the three `digitalWrite` calls used before this change.

- [ ] **Step 3: Make `configureLedChannel`'s `output_invert` polarity-aware**

Find:

```cpp
void configureLedChannel(int pin, ledc_channel_t channel) {
  ledc_channel_config_t channelConfig = {};
  channelConfig.gpio_num = pin;
  channelConfig.speed_mode = LED_PWM_MODE;
  channelConfig.channel = channel;
  channelConfig.timer_sel = LED_PWM_TIMER;
  channelConfig.duty = 0;                 // 反相后 = 高电平 = 灭
  channelConfig.hpoint = 0;
  channelConfig.flags.output_invert = 1;
  ledc_channel_config(&channelConfig);
}
```

Replace with:

```cpp
void configureLedChannel(int pin, ledc_channel_t channel) {
  ledc_channel_config_t channelConfig = {};
  channelConfig.gpio_num = pin;
  channelConfig.speed_mode = LED_PWM_MODE;
  channelConfig.channel = channel;
  channelConfig.timer_sel = LED_PWM_TIMER;
  channelConfig.duty = 0;                 // 灭：具体对应哪个电平由 output_invert 决定
  channelConfig.hpoint = 0;
  // 低电平点亮（默认）需要反相：duty=0 时输出高电平=灭。高电平点亮则不反相，
  // duty=0 时输出低电平=灭。writeLedChannel()的 duty = PWM_MAX - value 公式对两种
  // 极性都成立，因此这里是极性生效的唯一位置——上层的亮度/动画代码完全不用感知极性。
  channelConfig.flags.output_invert = ledActiveHigh ? 0 : 1;
  ledc_channel_config(&channelConfig);
}
```

**Active-low regression check for this step:** with `ledActiveHigh == false`, `output_invert` evaluates to `1` — identical to the hard-coded value before this change.

- [ ] **Step 4: Make `driveTestPin` (used by `PINTEST`) polarity-aware**

Find:

```cpp
void driveTestPin(int pin, bool on) {
  gpio_reset_pin((gpio_num_t)pin);
  pinMode(pin, OUTPUT);
  digitalWrite(pin, on ? LOW : HIGH);
}
```

Replace with:

```cpp
void driveTestPin(int pin, bool on) {
  gpio_reset_pin((gpio_num_t)pin);
  pinMode(pin, OUTPUT);
  int onLevel = ledActiveHigh ? HIGH : LOW;
  int offLevel = ledActiveHigh ? LOW : HIGH;
  digitalWrite(pin, on ? onLevel : offLevel);
}
```

**Active-low regression check for this step:** with `ledActiveHigh == false`, `onLevel == LOW` and `offLevel == HIGH` — identical to the hard-coded `on ? LOW : HIGH` before this change.

- [ ] **Step 5: Compile check**

```bash
cd /Users/itdragons/github/open-vibe-island/signal-light/esp32c3
./build-firmware.sh 1.3.0
```

Expected: `>>> 完成: .../firmware/esp32c3-1.3.0.bin`, no compile errors.

- [ ] **Step 6: Commit**

```bash
git add signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.3.0.ino
git commit -m "feat(esp32c3): make LED polarity a runtime-configurable flag"
```

---

### Task 3: Firmware — `SETPOLARITY` command and `GETCONFIG` field

**Files:**
- Modify: `signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.3.0.ino`

**Interfaces:**
- Consumes: `bool ledActiveHigh` global from Task 2; `Preferences prefs`, `setOtaStatus(const String&)`, `splitCommandFields(...)`, `configureAllLedChannels()` (all pre-existing).
- Produces: the `SETPOLARITY:LOW|HIGH` command (dispatched from `handleCommand`) and the `POL=LOW|HIGH` field appended to `sendConfigStatus()`'s reply — both consumed by Task 5's Swift decoder/encoder.

- [ ] **Step 1: Add the forward declaration**

Find:

```cpp
void handleBrightnessCommand(String cmd);
```

Add immediately after it:

```cpp
void handleSetPolarityCommand(String cmd);
```

- [ ] **Step 2: Dispatch the new command in `handleCommand`**

Find:

```cpp
  if (cmd.startsWith("BRIGHTNESS:")) {
    handleBrightnessCommand(cmd);
    return;
  }

  if (handleModeCommand(cmd)) {
    return;
  }
```

Replace with:

```cpp
  if (cmd.startsWith("BRIGHTNESS:")) {
    handleBrightnessCommand(cmd);
    return;
  }

  if (cmd.startsWith("SETPOLARITY:")) {
    handleSetPolarityCommand(cmd);
    return;
  }

  if (handleModeCommand(cmd)) {
    return;
  }
```

- [ ] **Step 3: Implement the handler**

Find `handleBrightnessCommand`'s closing brace (end of the function):

```cpp
void handleBrightnessCommand(String cmd) {
  // 格式：BRIGHTNESS:<0-100>
  String fields[1];
  if (!splitCommandFields(cmd, ':', fields, 1)) {
    setOtaStatus("BRIGHTNESS failed: malformed command");
    return;
  }

  int percent = fields[0].toInt();
  brightnessPercent = constrain(percent, 0, 100);
}
```

Add immediately after it:

```cpp

// 切换 LED 接线极性（低电平点亮 / 高电平点亮），持久化到 NVS 并立即生效，无需重启：
// 重新配置三路 LEDC 通道的 output_invert 即可，同一份亮度/动画代码在两种极性下都正确
// （见 configureLedChannel 的注释）。
void handleSetPolarityCommand(String cmd) {
  // 格式：SETPOLARITY:<LOW|HIGH>
  String fields[1];
  if (!splitCommandFields(cmd, ':', fields, 1)) {
    setOtaStatus("SETPOLARITY failed: malformed command");
    return;
  }

  String valueText = fields[0];
  bool newActiveHigh;
  if (valueText == "HIGH") {
    newActiveHigh = true;
  } else if (valueText == "LOW") {
    newActiveHigh = false;
  } else {
    setOtaStatus("SETPOLARITY failed: unknown value " + valueText);
    return;
  }

  ledActiveHigh = newActiveHigh;
  prefs.putBool("ledActiveHigh", ledActiveHigh);
  configureAllLedChannels();
  setOtaStatus("SETPOLARITY ok: " + valueText);
}
```

- [ ] **Step 4: Add the `POL` field to `GETCONFIG`'s reply**

Find:

```cpp
void sendConfigStatus() {
  String status = "CONFIG:R=" + String(led_red) +
                   ",Y=" + String(led_yellow) +
                   ",G=" + String(led_green) +
                   ",NAME=" + bleName;
  setOtaStatus(status);
}
```

Replace with:

```cpp
void sendConfigStatus() {
  String status = "CONFIG:R=" + String(led_red) +
                   ",Y=" + String(led_yellow) +
                   ",G=" + String(led_green) +
                   ",NAME=" + bleName +
                   ",POL=" + (ledActiveHigh ? "HIGH" : "LOW");
  setOtaStatus(status);
}
```

- [ ] **Step 5: Compile check**

```bash
cd /Users/itdragons/github/open-vibe-island/signal-light/esp32c3
./build-firmware.sh 1.3.0
```

Expected: `>>> 完成: .../firmware/esp32c3-1.3.0.bin`, no compile errors. This produces the final `esp32c3-1.3.0.bin` used by Task 4.

- [ ] **Step 6: Commit**

```bash
git add signal-light/esp32c3/esp32c3-1.3.0/esp32c3-1.3.0.ino
git commit -m "feat(esp32c3): add SETPOLARITY command and GETCONFIG POL field"
```

---

### Task 4: Firmware release metadata

**Files:**
- Modify: `signal-light/esp32c3/firmware/version.json`

**Interfaces:**
- Consumes: `signal-light/esp32c3/firmware/esp32c3-1.3.0.bin` produced by Task 3's compile check.
- Produces: nothing consumed by later tasks — this is release metadata for the app's online-update checker, independent of the app-side code tasks below.

- [ ] **Step 1: Update `version.json`**

Replace the full contents of `signal-light/esp32c3/firmware/version.json` with:

```json
{
  "hardware": "esp32c3",
  "version": "1.3.0",
  "binary": "esp32c3-1.3.0.bin",
  "notes": "新增 LED 接线极性切换：支持高电平点亮的硬件，默认仍沿用低电平点亮，已有设备无需任何操作。",
  "history": [
    "1.0.0: 首次可在线检测更新的固件版本。",
    "1.1.0: 未连接蓝牙时三色灯呼吸提示。",
    "1.2.0: 适配无线充电款，新增物理按键控制开关机（深度休眠/唤醒）；插电款无需升级。",
    "1.2.1: 修复低电量开机时三色灯一直微亮频闪、按键还关不了机的问题：电量不足时直接进入深度睡眠，按键唤醒后再重试开机。",
    "1.2.2: 修复开机瞬间三色灯闪烁的问题。",
    "1.3.0: 新增 LED 接线极性切换（SETPOLARITY 命令 + GETCONFIG 上报），支持高电平点亮的硬件；默认沿用低电平点亮，已有设备无需操作。"
  ]
}
```

- [ ] **Step 2: Verify the referenced binary exists**

```bash
ls -la /Users/itdragons/github/open-vibe-island/signal-light/esp32c3/firmware/esp32c3-1.3.0.bin
```

Expected: file exists (produced by Task 3, Step 5).

- [ ] **Step 3: Commit**

```bash
cd /Users/itdragons/github/open-vibe-island
git add signal-light/esp32c3/firmware/version.json signal-light/esp32c3/firmware/esp32c3-1.3.0.bin
git commit -m "chore(esp32c3): publish firmware 1.3.0"
```

---

### Task 5: App protocol layer — `SignalLight.swift` + tests

**Files:**
- Modify: `Sources/OpenIslandCore/SignalLight.swift`
- Modify: `Tests/OpenIslandCoreTests/SignalLightTests.swift`

**Interfaces:**
- Consumes: nothing from prior tasks (pure Swift, independent of the firmware tasks above).
- Produces:
  - `SignalLightControlCommand.setPolarity(activeHigh: Bool) -> String`
  - `SignalLightDeviceConfig.activeHigh: Bool` (new stored property; `init(pins:name:activeHigh:)` with `activeHigh` defaulting to `false`)
  - `SignalLightConfigDecoder.decode(_:)` now populates `activeHigh` from a `POL` field, defaulting to `false` when absent.
  
  Task 6 (`SignalLightCoordinator`) and Task 7 (`SignalLightSettingsPane`) both call `SignalLightControlCommand.setPolarity` and read `SignalLightDeviceConfig.activeHigh`.

- [ ] **Step 1: Add `setPolarity` to `SignalLightControlCommand`**

In `Sources/OpenIslandCore/SignalLight.swift`, find:

```swift
    public static func brightness(percent: Int) -> String {
        "BRIGHTNESS:\(percent)"
    }

    public static let off = "OFF"
}
```

Replace with:

```swift
    public static func brightness(percent: Int) -> String {
        "BRIGHTNESS:\(percent)"
    }

    public static func setPolarity(activeHigh: Bool) -> String {
        "SETPOLARITY:\(activeHigh ? "HIGH" : "LOW")"
    }

    public static let off = "OFF"
}
```

- [ ] **Step 2: Add `activeHigh` to `SignalLightDeviceConfig`**

Find:

```swift
public struct SignalLightDeviceConfig: Equatable, Sendable {
    public var pins: [SignalLightColor: Int]
    public var name: String

    public init(pins: [SignalLightColor: Int], name: String) {
        self.pins = pins
        self.name = name
    }
}
```

Replace with:

```swift
public struct SignalLightDeviceConfig: Equatable, Sendable {
    public var pins: [SignalLightColor: Int]
    public var name: String
    public var activeHigh: Bool

    public init(pins: [SignalLightColor: Int], name: String, activeHigh: Bool = false) {
        self.pins = pins
        self.name = name
        self.activeHigh = activeHigh
    }
}
```

- [ ] **Step 3: Parse the `POL` field in `SignalLightConfigDecoder`**

Find:

```swift
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
```

Replace with:

```swift
    public static func decode(_ line: String) -> SignalLightDeviceConfig? {
        guard line.hasPrefix("CONFIG:") else {
            return nil
        }

        var pins: [SignalLightColor: Int] = [:]
        var name: String?
        var activeHigh = false

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
            case "POL": activeHigh = (value == "HIGH")
            default: break
            }
        }

        guard pins.count == 3, let name else {
            return nil
        }
        return SignalLightDeviceConfig(pins: pins, name: name, activeHigh: activeHigh)
    }
```

- [ ] **Step 4: Add test coverage**

In `Tests/OpenIslandCoreTests/SignalLightTests.swift`, find:

```swift
    @Test
    func exposesGetConfigAndOffAsFixedStrings() {
        #expect(SignalLightControlCommand.getConfig == "GETCONFIG")
        #expect(SignalLightControlCommand.off == "OFF")
    }
}
```

Replace with:

```swift
    @Test
    func exposesGetConfigAndOffAsFixedStrings() {
        #expect(SignalLightControlCommand.getConfig == "GETCONFIG")
        #expect(SignalLightControlCommand.off == "OFF")
    }

    @Test
    func encodesSetPolarityLow() {
        #expect(SignalLightControlCommand.setPolarity(activeHigh: false) == "SETPOLARITY:LOW")
    }

    @Test
    func encodesSetPolarityHigh() {
        #expect(SignalLightControlCommand.setPolarity(activeHigh: true) == "SETPOLARITY:HIGH")
    }
}
```

Then find:

```swift
    @Test
    func rejectsUnrelatedStatusText() {
        #expect(SignalLightConfigDecoder.decode("SETPIN ok: R=5") == nil)
    }
```

Replace with:

```swift
    @Test
    func rejectsUnrelatedStatusText() {
        #expect(SignalLightConfigDecoder.decode("SETPIN ok: R=5") == nil)
    }

    @Test
    func decodesActiveHighPolarity() {
        let config = SignalLightConfigDecoder.decode("CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2,POL=HIGH")
        #expect(config == SignalLightDeviceConfig(pins: [.red: 5, .yellow: 6, .green: 7], name: "WG-A1B2", activeHigh: true))
    }

    @Test
    func defaultsToActiveLowWhenPolarityFieldIsAbsent() {
        let config = SignalLightConfigDecoder.decode("CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2")
        #expect(config?.activeHigh == false)
    }
```

- [ ] **Step 5: Run the tests**

```bash
cd /Users/itdragons/github/open-vibe-island
swift test --filter SignalLightControlCommandTests --filter SignalLightConfigDecoderTests
```

Expected: all tests pass, including the 4 new ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenIslandCore/SignalLight.swift Tests/OpenIslandCoreTests/SignalLightTests.swift
git commit -m "feat(core): add signal-light polarity command, config field, and tests"
```

---

### Task 6: App connection layer — `SignalLightCoordinator`

**Files:**
- Modify: `Sources/OpenIslandApp/SignalLightCoordinator.swift`

**Interfaces:**
- Consumes: `SignalLightControlCommand.getConfig` (existing), `SignalLightDeviceConfig` (Task 5).
- Produces: `lastDeviceConfig` (existing `private(set) var`, already `@Observable`-tracked) now reliably populates after every connect and clears on disconnect — Task 7's Settings UI reads it directly.

- [ ] **Step 1: Send `GETCONFIG` on connect**

In `Sources/OpenIslandApp/SignalLightCoordinator.swift`, find (inside `peripheral(_:didDiscoverCharacteristicsFor:error:)`):

```swift
            if let brightness = currentBrightnessProvider?() {
                sendRaw(SignalLightControlCommand.brightness(percent: brightness))
            }
        }
    }
```

Replace with:

```swift
            if let brightness = currentBrightnessProvider?() {
                sendRaw(SignalLightControlCommand.brightness(percent: brightness))
            }

            // Polarity is a hardware fact about this specific device (like its pin
            // mapping), not a user preference like brightness/effect — read it back
            // from the device rather than pushing a locally-remembered value, so a
            // stale local default can never overwrite a correct on-device setting.
            sendRaw(SignalLightControlCommand.getConfig)
        }
    }
```

- [ ] **Step 2: Clear `lastDeviceConfig` on disconnect**

Find (inside `centralManager(_:didDisconnectPeripheral:error:)`):

```swift
            connectedPeripheral = nil
            commandCharacteristic = nil
            otaControlCharacteristic = nil
            otaDataCharacteristic = nil
            firmwareVersion = nil
            hardwareID = nil
            firmwareUpdater.handleUnexpectedDisconnect()
```

Replace with:

```swift
            connectedPeripheral = nil
            commandCharacteristic = nil
            otaControlCharacteristic = nil
            otaDataCharacteristic = nil
            firmwareVersion = nil
            hardwareID = nil
            lastDeviceConfig = nil
            firmwareUpdater.handleUnexpectedDisconnect()
```

- [ ] **Step 3: Build check**

```bash
cd /Users/itdragons/github/open-vibe-island
swift build
```

Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenIslandApp/SignalLightCoordinator.swift
git commit -m "feat(app): read signal-light config (incl. polarity) on every connect"
```

---

### Task 7: Settings UI — polarity row, wizard escape hatch, localization

**Files:**
- Modify: `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`
- Modify: `Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hant.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `model.signalLight.lastDeviceConfig: SignalLightDeviceConfig?` (Task 6), `SignalLightControlCommand.setPolarity(activeHigh:)` / `.getConfig` / `.pinTest(pin:on:)` (Task 5, pre-existing), `model.signalLight.isCalibrating: Bool` (pre-existing).
- Produces: nothing consumed by later tasks — this is the final task.

- [ ] **Step 1: Add calibration-polarity tracking state**

In `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`, find:

```swift
    @State private var lightSwitchWasOnBeforeCalibration = false
```

Add immediately after it:

```swift
    @State private var calibrationAssumedActiveHigh = false
```

- [ ] **Step 2: Seed the assumed polarity when calibration begins**

Find:

```swift
    private func beginCalibration() {
        if !model.signalLight.isCalibrating {
            lightSwitchWasOnBeforeCalibration = model.signalLightEnabled
            model.signalLightEnabled = false
        }
        // Always clear the device before testing (including on "Redo") so a
```

Replace with:

```swift
    private func beginCalibration() {
        if !model.signalLight.isCalibrating {
            lightSwitchWasOnBeforeCalibration = model.signalLightEnabled
            model.signalLightEnabled = false
        }
        calibrationAssumedActiveHigh = model.signalLight.lastDeviceConfig?.activeHigh ?? false
        // Always clear the device before testing (including on "Redo") so a
```

- [ ] **Step 3: Add the escape-hatch action and refresh config after calibration finishes**

Find:

```swift
    private func applyCalibrationResult(_ finished: SignalLightCalibrationWizard) {
        for (color, pin) in finished.mapping {
            model.signalLight.sendRaw(SignalLightControlCommand.setPin(color: color, pin: pin))
        }
        if finished.unresolvedColors.isEmpty {
            model.signalLight.send(SignalLightEffect(type: .cycle, colors: [.green, .yellow, .red], intervalMs: 200))
        }
    }
```

Replace with:

```swift
    private func applyCalibrationResult(_ finished: SignalLightCalibrationWizard) {
        for (color, pin) in finished.mapping {
            model.signalLight.sendRaw(SignalLightControlCommand.setPin(color: color, pin: pin))
        }
        if finished.unresolvedColors.isEmpty {
            model.signalLight.send(SignalLightEffect(type: .cycle, colors: [.green, .yellow, .red], intervalMs: 200))
        }
        // Refresh the cached device config so the standalone polarity toggle
        // reflects the final value immediately, without waiting for a reconnect.
        model.signalLight.sendRaw(SignalLightControlCommand.getConfig)
    }

    /// Flips the polarity assumed during calibration and re-tests the current
    /// candidate pin under it — an escape hatch for when the wrong polarity
    /// makes every candidate pin look dead. Does not advance the wizard's
    /// index or touch its recorded mapping.
    private func tryOtherPolarityDuringCalibration() {
        guard let pin = wizard?.currentPin else { return }
        calibrationAssumedActiveHigh.toggle()
        model.signalLight.sendRaw(SignalLightControlCommand.setPolarity(activeHigh: calibrationAssumedActiveHigh))
        model.signalLight.sendRaw(SignalLightControlCommand.pinTest(pin: pin, on: true))
    }
```

- [ ] **Step 4: Add the escape-hatch button to the wizard view**

Find:

```swift
                HStack(spacing: 8) {
                    Button(lang.t("settings.signalLight.green")) { recordCalibrationObservation(.green) }
                    Button(lang.t("settings.signalLight.yellow")) { recordCalibrationObservation(.yellow) }
                    Button(lang.t("settings.signalLight.red")) { recordCalibrationObservation(.red) }
                    Button(lang.t("settings.signalLight.calibrateNothing")) { recordCalibrationObservation(.nothing) }
                }

                Button(lang.t("settings.general.cancel"), role: .cancel) {
                    cancelCalibration()
                }
```

Replace with:

```swift
                HStack(spacing: 8) {
                    Button(lang.t("settings.signalLight.green")) { recordCalibrationObservation(.green) }
                    Button(lang.t("settings.signalLight.yellow")) { recordCalibrationObservation(.yellow) }
                    Button(lang.t("settings.signalLight.red")) { recordCalibrationObservation(.red) }
                    Button(lang.t("settings.signalLight.calibrateNothing")) { recordCalibrationObservation(.nothing) }
                }

                Button(lang.t("settings.signalLight.calibrateTryOtherPolarity")) {
                    tryOtherPolarityDuringCalibration()
                }
                .font(.caption)

                Button(lang.t("settings.general.cancel"), role: .cancel) {
                    cancelCalibration()
                }
```

- [ ] **Step 5: Add the standalone polarity row**

Find:

```swift
    private func presentChangelog() {
```

Add immediately before it:

```swift
    @ViewBuilder
    private var polarityRow: some View {
        Picker(lang.t("settings.signalLight.polarity"), selection: Binding(
            get: { model.signalLight.lastDeviceConfig?.activeHigh ?? false },
            set: { newValue in
                model.signalLight.sendRaw(SignalLightControlCommand.setPolarity(activeHigh: newValue))
                model.signalLight.sendRaw(SignalLightControlCommand.getConfig)
            }
        )) {
            Text(lang.t("settings.signalLight.polarityLow")).tag(false)
            Text(lang.t("settings.signalLight.polarityHigh")).tag(true)
        }
        .disabled(isTransferring || model.signalLight.isCalibrating)
    }

```

- [ ] **Step 6: Insert the row into the device-management section**

Find:

```swift
                        if case .connected = model.signalLight.status {
                            VStack(alignment: .leading, spacing: 10) {
                                renameRow
                                Divider()
                                firmwareVersionRow
                                firmwareRow
                                firmwareActionRow
                            }
                        } else {
```

Replace with:

```swift
                        if case .connected = model.signalLight.status {
                            VStack(alignment: .leading, spacing: 10) {
                                renameRow
                                Divider()
                                polarityRow
                                Divider()
                                firmwareVersionRow
                                firmwareRow
                                firmwareActionRow
                            }
                        } else {
```

- [ ] **Step 7: Add the 4 new localized strings to all three locale files**

In `Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings`, find:

```
"settings.signalLight.calibrateDone" = "Done";
```

Add immediately after it:

```
"settings.signalLight.polarity" = "LED Wiring Polarity";
"settings.signalLight.polarityLow" = "Active-Low";
"settings.signalLight.polarityHigh" = "Active-High";
"settings.signalLight.calibrateTryOtherPolarity" = "Light won't turn on? Try the other polarity";
```

In `Sources/OpenIslandApp/Resources/zh-Hans.lproj/Localizable.strings`, find:

```
"settings.signalLight.calibrateDone" = "完成";
```

Add immediately after it:

```
"settings.signalLight.polarity" = "LED 接线极性";
"settings.signalLight.polarityLow" = "低电平点亮";
"settings.signalLight.polarityHigh" = "高电平点亮";
"settings.signalLight.calibrateTryOtherPolarity" = "灯一直不亮？试试另一种电平极性";
```

In `Sources/OpenIslandApp/Resources/zh-Hant.lproj/Localizable.strings`, find:

```
"settings.signalLight.calibrateDone" = "完成";
```

Add immediately after it:

```
"settings.signalLight.polarity" = "LED 接線極性";
"settings.signalLight.polarityLow" = "低電平點亮";
"settings.signalLight.polarityHigh" = "高電平點亮";
"settings.signalLight.calibrateTryOtherPolarity" = "燈一直不亮？試試另一種電平極性";
```

- [ ] **Step 8: Full build and test verification**

```bash
cd /Users/itdragons/github/open-vibe-island
swift build
swift test
```

Expected: both succeed with no errors and no test failures (the full suite, not just the signal-light filters used in Task 5 — this is the final gate for the whole feature).

- [ ] **Step 9: Commit**

```bash
git add Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift \
        Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings \
        Sources/OpenIslandApp/Resources/zh-Hans.lproj/Localizable.strings \
        Sources/OpenIslandApp/Resources/zh-Hant.lproj/Localizable.strings
git commit -m "feat(app): add signal-light polarity toggle and calibration escape hatch"
```

---

## Manual hardware verification (not agent-executable)

The following require physical hardware and must be performed by the user — flag this clearly when the plan finishes rather than claiming full completion:

1. Flash `firmware/esp32c3-1.3.0.bin` to a real active-low unit (`bridge-ctl.sh --ota` or the app's Settings → firmware flash) and confirm every mode/effect/brightness/manual control still renders identically to `1.2.2` — this is the concrete proof the active-low-regression constraint holds in practice, not just in the line-by-line checks noted in Task 2.
2. Wire a spare LED active-high, flash the same binary, select "Active-High" in Settings, and confirm all modes render correctly.
3. With the device set to the wrong polarity relative to its actual wiring, open the calibration wizard, confirm every candidate pin looks dead, use "Light won't turn on? Try the other polarity," and confirm the wizard recovers and completes from the same pin.
4. Power-cycle the device after setting polarity and confirm `GETCONFIG` reads it back correctly on reconnect.
5. Reinstall the app (or clear its UserDefaults) and confirm the polarity row reflects the device's actual on-device setting rather than resetting to "Active-Low" display before the first `GETCONFIG` reply lands.
