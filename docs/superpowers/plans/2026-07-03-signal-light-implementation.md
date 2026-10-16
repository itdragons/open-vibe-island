# Signal Light BLE Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a BLE-connected physical "signal light" as a companion status indicator for Open Island — Settings-based device pairing, per-session-state configurable light effects, and live linkage to real agent session state.

**Architecture:** Pure state/encoding logic lives in `OpenIslandCore` (`SignalLightBucketResolver`, `SignalLightCommandEncoder`). A CoreBluetooth-based `SignalLightCoordinator` in `OpenIslandApp` owns the device connection and auto-reconnect. `AppModel`'s existing `state` `didSet` resolves the current bucket and forwards the user's configured effect to the coordinator. A new Settings tab exposes device pairing and per-bucket effect configuration. Firmware (`led/led.ino`) gains one generic `EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>` command so the effect catalog is fully driven from the app, not hardcoded per named mode.

**Tech Stack:** Swift 6.2, SwiftUI, CoreBluetooth, Swift Testing (`swift-testing`), Arduino/C++ (ESP32-C3, BLE).

## Global Constraints

- This is a fork of an open-source project — every change must be additive. No existing command, mode, or OTA logic in `led.ino` may be modified or removed. No existing `SettingsTab`/pane may be restructured. `AppModel.swift`'s existing `state` `didSet` gets an appended block, not a rewrite.
- Single signal-light device only — no multi-device management in this iteration.
- No TDD — implement first, then add tests as a verification step (per explicit user instruction). Do not write failing tests before implementation.
- No firmware OTA-upload UI in this iteration — OTA stays a manual `test_ble.py`/USB workflow.
- No BLE write retry queue — a dropped write is superseded by the next real state change or reconnect resync (fail-open, matches the project's hooks philosophy).
- Native macOS APIs over cross-platform abstractions (CoreBluetooth directly, no third-party BLE wrapper).
- Platform floor: macOS 14+, Swift 6.2 (per `Package.swift`).
- All new Swift types go in new files; existing large files (`AppModel.swift`, `SettingsView.swift`) get the smallest possible touch point.
- Reply to the user in Chinese for all narration around this plan's execution (a session-level instruction from the user, not a code requirement).

---

### Task 1: Core effect/bucket model, priority resolver, and command encoder

**Files:**
- Create: `Sources/OpenIslandCore/SignalLight.swift`
- Test: `Tests/OpenIslandCoreTests/SignalLightTests.swift`

**Interfaces:**
- Produces:
  - `public enum SignalLightEffectType: String, Codable, Sendable, CaseIterable { case solid, blink, cycle, breathe }`
  - `public enum SignalLightColor: String, Codable, Sendable, CaseIterable { case red, yellow, green }`
  - `public struct SignalLightEffect: Codable, Sendable, Equatable { public var type: SignalLightEffectType; public var colors: [SignalLightColor]; public var intervalMs: Int; public init(type:colors:intervalMs:) }`
  - `public extension SignalLightEffect { static func defaultEffect(for bucket: SignalLightBucket) -> SignalLightEffect }`
  - `public enum SignalLightBucket: String, Codable, Sendable, CaseIterable, Hashable { case needsApproval, needsAnswer, running, idle }`
  - `public enum SignalLightBucketResolver { public static func resolve(_ state: SessionState) -> SignalLightBucket }`
  - `public enum SignalLightCommandEncoder { public static func encode(_ effect: SignalLightEffect) -> String; public static func decode(_ command: String) -> SignalLightEffect? }`
- Consumes: `SessionState` (`Sources/OpenIslandCore/SessionState.swift`, has `.sessions: [AgentSession]`), `AgentSession.phase: SessionPhase` (`Sources/OpenIslandCore/AgentSession.swift`, cases `.running`, `.waitingForApproval`, `.waitingForAnswer`, `.completed`).

- [ ] **Step 1: Implement the effect/bucket types, resolver, and encoder**

Create `Sources/OpenIslandCore/SignalLight.swift`:

```swift
import Foundation

/// How the signal light's LEDs behave for a given effect.
public enum SignalLightEffectType: String, Codable, Sendable, CaseIterable {
    case solid
    case blink
    case cycle
    case breathe
}

/// One of the signal light's three independently-addressable LEDs.
public enum SignalLightColor: String, Codable, Sendable, CaseIterable {
    case red
    case yellow
    case green

    var commandLetter: String {
        switch self {
        case .red: "R"
        case .yellow: "Y"
        case .green: "G"
        }
    }

    init?(commandLetter: Character) {
        switch commandLetter {
        case "R": self = .red
        case "Y": self = .yellow
        case "G": self = .green
        default: return nil
        }
    }
}

/// A fully-configurable light behavior: what type of animation, which
/// LEDs it involves (order matters for `.cycle`), and how fast.
public struct SignalLightEffect: Codable, Sendable, Equatable {
    public var type: SignalLightEffectType
    public var colors: [SignalLightColor]
    public var intervalMs: Int

    public init(type: SignalLightEffectType, colors: [SignalLightColor], intervalMs: Int) {
        self.type = type
        self.colors = colors
        self.intervalMs = intervalMs
    }
}

/// The four working-state buckets a single signal light can represent.
/// `idle` covers both "zero sessions" and "every session completed."
public enum SignalLightBucket: String, Codable, Sendable, CaseIterable, Hashable {
    case needsApproval
    case needsAnswer
    case running
    case idle
}

public extension SignalLightEffect {
    /// Sensible out-of-the-box behavior for each bucket, used to seed
    /// persisted settings on first run and as a fallback if a bucket is
    /// somehow missing from the user's configuration.
    static func defaultEffect(for bucket: SignalLightBucket) -> SignalLightEffect {
        switch bucket {
        case .idle:
            SignalLightEffect(type: .solid, colors: [.green], intervalMs: 0)
        case .running:
            SignalLightEffect(type: .blink, colors: [.yellow], intervalMs: 600)
        case .needsApproval, .needsAnswer:
            SignalLightEffect(type: .cycle, colors: [.red, .yellow, .green], intervalMs: 200)
        }
    }
}

/// Resolves which single bucket a physical signal light should currently
/// display, given that multiple agent sessions may be in different phases
/// at once but there is only one light. Priority: anything needing manual
/// attention outranks anything merely running, which outranks idle.
public enum SignalLightBucketResolver {
    public static func resolve(_ state: SessionState) -> SignalLightBucket {
        let sessions = state.sessions

        if sessions.contains(where: { $0.phase == .waitingForApproval }) {
            return .needsApproval
        }
        if sessions.contains(where: { $0.phase == .waitingForAnswer }) {
            return .needsAnswer
        }
        if sessions.contains(where: { $0.phase == .running }) {
            return .running
        }
        return .idle
    }
}

/// Encodes/decodes the generic `EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>` BLE
/// command understood by the signal light firmware (see `led/led.ino`).
/// Example: `EFFECT:CYCLE:RYG:200`.
public enum SignalLightCommandEncoder {
    public static func encode(_ effect: SignalLightEffect) -> String {
        let typeText = effect.type.rawValue.uppercased()
        let colorsText = effect.colors.map(\.commandLetter).joined()
        return "EFFECT:\(typeText):\(colorsText):\(effect.intervalMs)"
    }

    public static func decode(_ command: String) -> SignalLightEffect? {
        let parts = command.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "EFFECT" else {
            return nil
        }
        guard let type = SignalLightEffectType(rawValue: parts[1].lowercased()) else {
            return nil
        }

        var colors: [SignalLightColor] = []
        for character in parts[2] {
            guard let color = SignalLightColor(commandLetter: character) else {
                return nil
            }
            colors.append(color)
        }
        guard !colors.isEmpty else {
            return nil
        }
        guard let intervalMs = Int(parts[3]) else {
            return nil
        }

        return SignalLightEffect(type: type, colors: colors, intervalMs: intervalMs)
    }
}
```

- [ ] **Step 2: Build the package**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Write tests covering the resolver priority order and the encoder round-trip**

Create `Tests/OpenIslandCoreTests/SignalLightTests.swift`:

```swift
import Foundation
import Testing
@testable import OpenIslandCore

struct SignalLightBucketResolverTests {
    @Test
    func resolvesToNeedsApprovalWhenAnySessionIsWaitingForApproval() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .running),
            makeSession(id: "b", phase: .waitingForApproval),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .needsApproval)
    }

    @Test
    func resolvesToNeedsAnswerWhenNoApprovalButAnAnswerIsPending() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .completed),
            makeSession(id: "b", phase: .waitingForAnswer),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .needsAnswer)
    }

    @Test
    func resolvesToRunningWhenNoAttentionNeededButSomethingIsRunning() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .completed),
            makeSession(id: "b", phase: .running),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .running)
    }

    @Test
    func resolvesToIdleWhenAllSessionsAreCompleted() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .completed),
            makeSession(id: "b", phase: .completed),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .idle)
    }

    @Test
    func resolvesToIdleWhenThereAreNoSessions() {
        #expect(SignalLightBucketResolver.resolve(SessionState()) == .idle)
    }

    private func makeSession(id: String, phase: SessionPhase) -> AgentSession {
        AgentSession(
            id: id,
            title: "Test Session \(id)",
            tool: .codex,
            phase: phase,
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

struct SignalLightCommandEncoderTests {
    @Test
    func encodesSolidEffectWithSingleColor() {
        let effect = SignalLightEffect(type: .solid, colors: [.green], intervalMs: 0)
        #expect(SignalLightCommandEncoder.encode(effect) == "EFFECT:SOLID:G:0")
    }

    @Test
    func encodesCycleEffectWithOrderedColors() {
        let effect = SignalLightEffect(type: .cycle, colors: [.red, .yellow, .green], intervalMs: 200)
        #expect(SignalLightCommandEncoder.encode(effect) == "EFFECT:CYCLE:RYG:200")
    }

    @Test
    func decodeRoundTripsForEveryEffectType() {
        let effects: [SignalLightEffect] = [
            SignalLightEffect(type: .solid, colors: [.green], intervalMs: 0),
            SignalLightEffect(type: .blink, colors: [.yellow], intervalMs: 600),
            SignalLightEffect(type: .cycle, colors: [.red, .yellow, .green], intervalMs: 200),
            SignalLightEffect(type: .breathe, colors: [.red, .green], intervalMs: 2400),
        ]

        for effect in effects {
            let command = SignalLightCommandEncoder.encode(effect)
            #expect(SignalLightCommandEncoder.decode(command) == effect)
        }
    }

    @Test
    func decodeRejectsMalformedCommands() {
        #expect(SignalLightCommandEncoder.decode("EFFECT:SOLID:G") == nil)
        #expect(SignalLightCommandEncoder.decode("EFFECT:SPARKLE:G:0") == nil)
        #expect(SignalLightCommandEncoder.decode("EFFECT:SOLID:X:0") == nil)
        #expect(SignalLightCommandEncoder.decode("NOT_EFFECT:SOLID:G:0") == nil)
    }
}
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter SignalLight`
Expected: all `SignalLightBucketResolverTests` and `SignalLightCommandEncoderTests` cases PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandCore/SignalLight.swift Tests/OpenIslandCoreTests/SignalLightTests.swift
git commit -m "feat: add signal light effect model, bucket resolver, and command encoder"
```

---

### Task 2: Firmware — generic EFFECT command and renderer

**Files:**
- Modify: `signal-light/led/led.ino`

**Interfaces:**
- Consumes: the `EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>` command format from Task 1's `SignalLightCommandEncoder.encode(_:)` (e.g. `EFFECT:CYCLE:RYG:200`).
- Produces: nothing consumed by later Swift tasks — this is a standalone firmware change, verified manually.

This task is purely additive: every existing command, `LedMode` case, and OTA code path in `led.ino` stays untouched.

- [ ] **Step 1: Add the custom-effect state and `MODE_CUSTOM_EFFECT` mode**

In `signal-light/led/led.ino`, find the existing `LedMode` enum:

```cpp
enum LedMode {
  MODE_MANUAL,
  MODE_GREEN_BLINK,
  MODE_THINKING,
  MODE_WORKING,
  MODE_BUSY,
  MODE_SUCCESS,
  MODE_ERROR,
  MODE_ALARM
};
```

Add one case at the end:

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

Just below the existing `LedMode currentMode = MODE_MANUAL;` / `unsigned long lastFrameMs = 0;` / `int frame = 0;` block, add the custom-effect state:

```cpp
enum CustomEffectType {
  EFFECT_SOLID,
  EFFECT_BLINK,
  EFFECT_CYCLE,
  EFFECT_BREATHE
};

CustomEffectType customEffectType = EFFECT_SOLID;
int customEffectColors[3] = { -1, -1, -1 };
int customEffectColorCount = 0;
unsigned long customEffectIntervalMs = 0;
```

- [ ] **Step 2: Add forward declarations for the new functions**

Find the existing forward-declaration block:

```cpp
void handleCommand(String cmd);
void handleOtaControl(String cmd);
void handleOtaData(BLECharacteristic *characteristic);
void setOtaStatus(const String &message);
void startMode(LedMode mode);
bool isCommand(String cmd, String a, String b = "", String c = "", String d = "");
```

Add two more declarations to it:

```cpp
void handleCommand(String cmd);
void handleOtaControl(String cmd);
void handleOtaData(BLECharacteristic *characteristic);
void setOtaStatus(const String &message);
void startMode(LedMode mode);
bool isCommand(String cmd, String a, String b = "", String c = "", String d = "");
void handleEffectCommand(String cmd);
void animateCustomEffect(unsigned long nowMs);
```

- [ ] **Step 3: Dispatch `MODE_CUSTOM_EFFECT` from `updateLights()`**

Find the existing `updateLights()` if/else chain:

```cpp
  } else if (currentMode == MODE_ALARM) {
    animateAlarm(nowMs);
  }
}
```

Add one more branch before the closing brace:

```cpp
  } else if (currentMode == MODE_ALARM) {
    animateAlarm(nowMs);
  } else if (currentMode == MODE_CUSTOM_EFFECT) {
    animateCustomEffect(nowMs);
  }
}
```

- [ ] **Step 4: Parse the `EFFECT:...` command in `handleCommand`**

Find the start of `handleCommand`:

```cpp
void handleCommand(String cmd) {
  cmd.trim();
  cmd.toUpperCase();

  if (cmd.length() == 0) {
    return;
  }

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

Insert a new check right after the length check, before the existing `GREEN_BLINK` branch:

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

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
```

- [ ] **Step 5: Implement `handleEffectCommand` and the custom-effect renderer**

Add these two new functions near the other `handle*`/`animate*` functions (e.g. right after `animateAlarm`, before `handleCommand`):

```cpp
void handleEffectCommand(String cmd) {
  // Format: EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>, e.g. EFFECT:CYCLE:RYG:200
  int firstColon = cmd.indexOf(':');
  int secondColon = cmd.indexOf(':', firstColon + 1);
  int thirdColon = cmd.indexOf(':', secondColon + 1);

  if (firstColon < 0 || secondColon < 0 || thirdColon < 0) {
    return;
  }

  String typeText = cmd.substring(firstColon + 1, secondColon);
  String colorsText = cmd.substring(secondColon + 1, thirdColon);
  String intervalText = cmd.substring(thirdColon + 1);

  CustomEffectType parsedType;
  if (typeText == "SOLID") {
    parsedType = EFFECT_SOLID;
  } else if (typeText == "BLINK") {
    parsedType = EFFECT_BLINK;
  } else if (typeText == "CYCLE") {
    parsedType = EFFECT_CYCLE;
  } else if (typeText == "BREATHE") {
    parsedType = EFFECT_BREATHE;
  } else {
    return;
  }

  int parsedColors[3];
  int parsedColorCount = 0;
  for (unsigned int i = 0; i < colorsText.length() && parsedColorCount < 3; i++) {
    char c = colorsText.charAt(i);
    if (c == 'R') {
      parsedColors[parsedColorCount++] = led_red;
    } else if (c == 'Y') {
      parsedColors[parsedColorCount++] = led_yellow;
    } else if (c == 'G') {
      parsedColors[parsedColorCount++] = led_green;
    }
  }

  if (parsedColorCount == 0) {
    return;
  }

  long parsedInterval = intervalText.toInt();
  if (parsedInterval < 0) {
    return;
  }

  customEffectType = parsedType;
  customEffectColorCount = parsedColorCount;
  for (int i = 0; i < parsedColorCount; i++) {
    customEffectColors[i] = parsedColors[i];
  }
  customEffectIntervalMs = (unsigned long)parsedInterval;

  startMode(MODE_CUSTOM_EFFECT);
}

void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex) {
  for (int i = 0; i < customEffectColorCount; i++) {
    if (activeIndex >= 0 && i != activeIndex) {
      continue;
    }
    int pin = customEffectColors[i];
    if (pin == led_red) {
      red = onValue;
    } else if (pin == led_yellow) {
      yellow = onValue;
    } else if (pin == led_green) {
      green = onValue;
    }
  }
}

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

Also add a forward declaration for the small helper next to the other two added in Step 2:

```cpp
void handleEffectCommand(String cmd);
void animateCustomEffect(unsigned long nowMs);
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex);
```

- [ ] **Step 6: Flash and manually verify**

Flash the updated sketch to the ESP32-C3 over USB (Arduino IDE or `arduino-cli`, whichever the board was originally flashed with).

Using `test_ble.py` (already in `signal-light/`), connect to the board and send each of these at the free-text command prompt, confirming the described behavior on the physical LEDs each time:
- `EFFECT:SOLID:G:0` → green LED steady on, red/yellow off.
- `EFFECT:BLINK:Y:600` → yellow LED blinks on/off roughly every 600ms.
- `EFFECT:CYCLE:RYG:200` → red → yellow → green step in sequence, ~200ms per step.
- `EFFECT:BREATHE:RYG:2400` → all three LEDs fade up and down together over ~2.4s.
- `EFFECT:BOGUS:G:0` (malformed type) → no visible change, board stays in whatever mode it was already in (no crash/reset).
- `THINKING` (an existing named command) → still works exactly as before, confirming the new code didn't disturb existing behavior.

- [ ] **Step 7: Commit**

```bash
git add signal-light/led/led.ino
git commit -m "feat(firmware): add generic EFFECT command for configurable light effects"
```

---

### Task 3: SignalLightCoordinator (CoreBluetooth scan/connect/auto-reconnect/send)

**Files:**
- Create: `Sources/OpenIslandApp/SignalLightCoordinator.swift`

**Interfaces:**
- Consumes: `SignalLightEffect`, `SignalLightCommandEncoder.encode(_:)` from Task 1 (`OpenIslandCore`).
- Produces:
  - `enum SignalLightConnectionStatus: Equatable { case unauthorized, poweredOff, disconnected, scanning, connecting, connected(name: String) }`
  - `struct SignalLightDiscoveredDevice: Identifiable, Equatable { let id: UUID; let name: String }`
  - `@MainActor @Observable final class SignalLightCoordinator: NSObject { private(set) var status: SignalLightConnectionStatus; private(set) var discoveredDevices: [SignalLightDiscoveredDevice]; var currentEffectProvider: (() -> SignalLightEffect?)?; func startScan(); func stopScan(); func connect(deviceID: UUID); func disconnect(); func send(_ effect: SignalLightEffect) }`
  - The BLE service/characteristic UUIDs are hardcoded to match `signal-light/led/config.h`'s `SERVICE_UUID` (`77697364-6f6d-6761-7264-656e00000001`) and `COMMAND_CHARACTERISTIC_UUID` (`77697364-6f6d-6761-7264-656e00000002`).

- [ ] **Step 1: Implement the coordinator**

Create `Sources/OpenIslandApp/SignalLightCoordinator.swift`:

```swift
import CoreBluetooth
import Foundation
import Observation
import OpenIslandCore

enum SignalLightConnectionStatus: Equatable {
    case unauthorized
    case poweredOff
    case disconnected
    case scanning
    case connecting
    case connected(name: String)
}

struct SignalLightDiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Owns the BLE connection to a single paired signal-light device: scanning,
/// connecting, disconnecting, auto-reconnecting after drops, and sending
/// effect commands. Talks directly to the peripheral defined in
/// `signal-light/led/led.ino` / `signal-light/led/config.h`.
@MainActor
@Observable
final class SignalLightCoordinator: NSObject {
    private static let serviceUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000001")
    private static let commandCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000002")
    private static let pairedPeripheralIDDefaultsKey = "signalLight.pairedPeripheralID"

    private(set) var status: SignalLightConnectionStatus = .disconnected
    private(set) var discoveredDevices: [SignalLightDiscoveredDevice] = []

    /// Supplies the effect that should currently be showing. Called right
    /// after a (re)connection completes so the light can resync to current
    /// reality instead of being left on whatever it displayed before a drop.
    var currentEffectProvider: (() -> SignalLightEffect?)?

    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var commandCharacteristic: CBCharacteristic?
    @ObservationIgnored private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard let centralManager, centralManager.state == .poweredOn else {
            return
        }
        discoveredDevices = []
        discoveredPeripherals = [:]
        status = .scanning
        centralManager.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    func stopScan() {
        centralManager?.stopScan()
        if status == .scanning {
            status = .disconnected
        }
    }

    func connect(deviceID: UUID) {
        guard let centralManager, let peripheral = discoveredPeripherals[deviceID] else {
            return
        }
        stopScan()
        status = .connecting
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.pairedPeripheralIDDefaultsKey)
        guard let centralManager, let peripheral = connectedPeripheral else {
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func send(_ effect: SignalLightEffect) {
        guard let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic,
              peripheral.state == .connected else {
            return
        }
        let command = SignalLightCommandEncoder.encode(effect)
        peripheral.writeValue(Data(command.utf8), for: characteristic, type: .withoutResponse)
    }

    private func attemptAutoReconnect() {
        guard let centralManager,
              let idString = UserDefaults.standard.string(forKey: Self.pairedPeripheralIDDefaultsKey),
              let id = UUID(uuidString: idString),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            return
        }
        status = .connecting
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }
}

extension SignalLightCoordinator: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                attemptAutoReconnect()
            case .unauthorized:
                status = .unauthorized
            case .poweredOff:
                status = .poweredOff
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            discoveredPeripherals[peripheral.identifier] = peripheral
            guard !discoveredDevices.contains(where: { $0.id == peripheral.identifier }) else {
                return
            }
            discoveredDevices.append(
                SignalLightDiscoveredDevice(id: peripheral.identifier, name: peripheral.name ?? "Signal Light")
            )
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.pairedPeripheralIDDefaultsKey)
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            connectedPeripheral = nil
            status = .disconnected
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            connectedPeripheral = nil
            commandCharacteristic = nil
            status = .disconnected
            attemptAutoReconnect()
        }
    }
}

extension SignalLightCoordinator: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                return
            }
            peripheral.discoverCharacteristics([Self.commandCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.commandCharacteristicUUID }) else {
                return
            }
            commandCharacteristic = characteristic
            status = .connected(name: peripheral.name ?? "Signal Light")
            if let effect = currentEffectProvider?() {
                send(effect)
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors. If the compiler reports Sendable/concurrency errors on the `CBCentralManagerDelegate`/`CBPeripheralDelegate` methods, keep the `nonisolated func ... { MainActor.assumeIsolated { ... } }` shape (this mirrors the existing `SPUUpdaterDelegate` pattern in `Sources/OpenIslandApp/UpdateChecker.swift:72-91`, adapted to use `assumeIsolated` since `CBCentralManager` is created with `queue: .main` so callbacks are already guaranteed to run on the main queue) and adjust only what the specific compiler error names.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenIslandApp/SignalLightCoordinator.swift
git commit -m "feat: add CoreBluetooth coordinator for the signal light device"
```

---

### Task 4: AppModel integration — persisted effect config + live state linkage

**Files:**
- Modify: `Sources/OpenIslandApp/AppModel.swift`

**Interfaces:**
- Consumes: `SignalLightCoordinator` (Task 3), `SignalLightEffect`, `SignalLightBucket`, `SignalLightBucketResolver`, `SignalLightEffect.defaultEffect(for:)` (Task 1).
- Produces: `AppModel.signalLight: SignalLightCoordinator` (readable by Settings UI in Task 5), `AppModel.signalLightEffects: [SignalLightBucket: SignalLightEffect]` (read/write, backed by UserDefaults key `signalLight.effects`).

- [ ] **Step 1: Add the coordinator property and persisted effects dictionary**

In `Sources/OpenIslandApp/AppModel.swift`, find the coordinator declarations (around line 65-69):

```swift
    let hooks = HookInstallationCoordinator()
    let overlay = OverlayUICoordinator()
    let discovery = SessionDiscoveryCoordinator()
    let monitoring = ProcessMonitoringCoordinator()
    let codexAppServer = CodexAppServerCoordinator()
```

Add the new coordinator right after it:

```swift
    let hooks = HookInstallationCoordinator()
    let overlay = OverlayUICoordinator()
    let discovery = SessionDiscoveryCoordinator()
    let monitoring = ProcessMonitoringCoordinator()
    let codexAppServer = CodexAppServerCoordinator()
    let signalLight = SignalLightCoordinator()
```

Find the static UserDefaults keys near the top of the class (around line 18-20):

```swift
    private static let soundMutedDefaultsKey = "overlay.sound.muted"
    private static let showDockIconDefaultsKey = "app.showDockIcon"
    private static let hapticFeedbackEnabledDefaultsKey = "app.hapticFeedbackEnabled"
```

Add one more key:

```swift
    private static let soundMutedDefaultsKey = "overlay.sound.muted"
    private static let showDockIconDefaultsKey = "app.showDockIcon"
    private static let hapticFeedbackEnabledDefaultsKey = "app.hapticFeedbackEnabled"
    private static let signalLightEffectsDefaultsKey = "signalLight.effects"
```

Find the `state` property (around line 47):

```swift
    var state = SessionState() {
        didSet {
            _cachedSessionBuckets = nil
            pruneAgentsGridObservationTicketsIfNeeded()
            bridgeServer.updateStateSnapshot(state)
        }
    }
```

Replace it with a version that also resolves and forwards the signal-light bucket:

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
    @ObservationIgnored private var lastSentSignalLightBucket: SignalLightBucket?
```

Add the persisted effects dictionary and its loader as a new property + static method. Place the property next to `watchNotificationEnabled` (around line 435) and the static loader next to `loadAppearancePreferences` (around line 570):

```swift
    var signalLightEffects: [SignalLightBucket: SignalLightEffect] = Self.loadSignalLightEffects() {
        didSet {
            guard let data = try? JSONEncoder().encode(signalLightEffects) else {
                return
            }
            UserDefaults.standard.set(data, forKey: Self.signalLightEffectsDefaultsKey)
        }
    }

    private static func loadSignalLightEffects() -> [SignalLightBucket: SignalLightEffect] {
        if let data = UserDefaults.standard.data(forKey: signalLightEffectsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SignalLightBucket: SignalLightEffect].self, from: data) {
            return decoded
        }
        return Dictionary(uniqueKeysWithValues: SignalLightBucket.allCases.map { ($0, .defaultEffect(for: $0)) })
    }
```

- [ ] **Step 2: Wire the reconnect-resync callback in `init`**

Find the coordinator-wiring block in `init` (around line 638-660, right after the `hooks.onStatusMessage = ...` block and before the `discovery.*` wiring):

```swift
        hooks.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }

        discovery.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
```

Insert the signal-light wiring between them:

```swift
        hooks.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }

        signalLight.currentEffectProvider = { [weak self] in
            guard let self else { return nil }
            let bucket = SignalLightBucketResolver.resolve(self.state)
            return self.signalLightEffects[bucket] ?? .defaultEffect(for: bucket)
        }

        discovery.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manually verify the linkage compiles into working behavior**

Run: `swift build -c debug --product OpenIslandApp && swift run OpenIslandApp`

There's no signal-light UI yet (that's Task 5), so full behavior can't be observed end-to-end. Confirm instead, via Xcode or a quick REPL-style check, that `AppModel().signalLightEffects` returns four entries (one per `SignalLightBucket` case) with the documented defaults, and that the app launches without crashing (confirms `SignalLightCoordinator()`'s `CBCentralManager` initialization doesn't throw/crash at startup even before Bluetooth permission is granted).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandApp/AppModel.swift
git commit -m "feat: link AppModel session state to the signal light coordinator"
```

---

### Task 5: Settings UI — SignalLightSettingsPane

**Files:**
- Create: `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`

**Interfaces:**
- Consumes: `AppModel.signalLight` (Task 4), `AppModel.signalLightEffects` (Task 4), `SignalLightBucket`, `SignalLightEffect`, `SignalLightEffectType`, `SignalLightColor` (Task 1), `SignalLightConnectionStatus`, `SignalLightDiscoveredDevice` (Task 3).
- Produces: `struct SignalLightSettingsPane: View { var model: AppModel }` — consumed by Task 6's `SettingsView`.

- [ ] **Step 1: Implement the pane**

Create `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`:

```swift
import AppKit
import SwiftUI
import OpenIslandCore

struct SignalLightSettingsPane: View {
    var model: AppModel

    var body: some View {
        Form {
            deviceSection
            modesSection
        }
        .formStyle(.grouped)
        .navigationTitle("Signal Light")
    }

    // MARK: Device

    @ViewBuilder
    private var deviceSection: some View {
        Section("Device") {
            HStack {
                Label("Status", systemImage: "light.beacon.max.fill")
                Spacer()
                statusBadge
            }

            switch model.signalLight.status {
            case .unauthorized:
                unauthorizedBanner
            case .poweredOff:
                Text("Turn on Bluetooth to search for a signal light.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connected:
                Button("Disconnect", role: .destructive) {
                    model.signalLight.disconnect()
                }
            default:
                discoveredDevicesList
                Button("Scan") {
                    model.signalLight.startScan()
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.signalLight.status {
        case .connected(let name):
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .connecting:
            ProgressView().controlSize(.small)
        case .scanning:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .disconnected:
            Text("Not connected")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .poweredOff:
            Text("Bluetooth off")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .unauthorized:
            Text("Permission needed")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var unauthorizedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open Island needs Bluetooth permission to find your signal light.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Bluetooth Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveredDevicesList: some View {
        if model.signalLight.discoveredDevices.isEmpty {
            Text(model.signalLight.status == .scanning ? "Searching…" : "No devices found yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.signalLight.discoveredDevices) { device in
                HStack {
                    Text(device.name)
                    Spacer()
                    Button("Connect") {
                        model.signalLight.connect(deviceID: device.id)
                    }
                }
            }
        }
    }

    // MARK: Modes

    @ViewBuilder
    private var modesSection: some View {
        Section("Modes") {
            ForEach(SignalLightBucket.allCases, id: \.self) { bucket in
                SignalLightModeRow(
                    title: bucketTitle(bucket),
                    effect: Binding(
                        get: { model.signalLightEffects[bucket] ?? .defaultEffect(for: bucket) },
                        set: { model.signalLightEffects[bucket] = $0 }
                    ),
                    onTest: { effect in
                        model.signalLight.send(effect)
                    }
                )
            }
        }
    }

    private func bucketTitle(_ bucket: SignalLightBucket) -> String {
        switch bucket {
        case .needsApproval: "Needs Approval"
        case .needsAnswer: "Needs Answer"
        case .running: "Running"
        case .idle: "Idle"
        }
    }
}

private struct SignalLightModeRow: View {
    let title: String
    @Binding var effect: SignalLightEffect
    let onTest: (SignalLightEffect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            Picker("Effect", selection: $effect.type) {
                Text("Solid").tag(SignalLightEffectType.solid)
                Text("Blink").tag(SignalLightEffectType.blink)
                Text("Cycle").tag(SignalLightEffectType.cycle)
                Text("Breathe").tag(SignalLightEffectType.breathe)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                colorToggle(.red, label: "Red")
                colorToggle(.yellow, label: "Yellow")
                colorToggle(.green, label: "Green")

                Spacer()

                if effect.type != .solid {
                    Stepper(
                        "\(effect.intervalMs) ms",
                        value: $effect.intervalMs,
                        in: 100...3000,
                        step: 100
                    )
                    .fixedSize()
                }

                Button("Test") {
                    onTest(effect)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func colorToggle(_ color: SignalLightColor, label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { effect.colors.contains(color) },
            set: { isOn in
                if isOn {
                    guard !effect.colors.contains(color) else { return }
                    effect.colors.append(color)
                } else {
                    effect.colors.removeAll { $0 == color }
                }
            }
        ))
        .toggleStyle(.button)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: fails with "cannot find 'SignalLightSettingsPane' in scope" style errors only if referenced elsewhere — at this point nothing references it yet, so it should build cleanly on its own. If it doesn't, fix the reported compiler errors in this file before proceeding.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift
git commit -m "feat: add Signal Light settings pane (device pairing + mode configuration)"
```

---

### Task 6: Wire the new tab into SettingsView

**Files:**
- Modify: `Sources/OpenIslandApp/Views/SettingsView.swift:7-87` (the `SettingsTab` enum)
- Modify: `Sources/OpenIslandApp/Views/SettingsView.swift:135-167` (`SettingsView.detailView`)

**Interfaces:**
- Consumes: `SignalLightSettingsPane` (Task 5).

- [ ] **Step 1: Add the new tab case**

In `Sources/OpenIslandApp/Views/SettingsView.swift`, find the `SettingsTab` enum's case list:

```swift
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case setup
    case display
    case sound
    case appearance
    case watch
    case shortcuts
    case lab
    case about
```

Add `signalLight` right after `watch`:

```swift
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case setup
    case display
    case sound
    case appearance
    case watch
    case signalLight
    case shortcuts
    case lab
    case about
```

Find the `label(_:)` switch:

```swift
        case .watch:      "Watch"
        case .shortcuts:  lang.t("settings.tab.shortcuts")
```

Add a case for the new tab:

```swift
        case .watch:      "Watch"
        case .signalLight: "Signal Light"
        case .shortcuts:  lang.t("settings.tab.shortcuts")
```

Find the `icon` switch:

```swift
        case .watch:      "applewatch"
        case .shortcuts:  "keyboard.fill"
```

Add a case:

```swift
        case .watch:      "applewatch"
        case .signalLight: "light.beacon.max.fill"
        case .shortcuts:  "keyboard.fill"
```

Find the `iconColor` switch:

```swift
        case .watch:      .cyan
        case .shortcuts:  .gray
```

Add a case:

```swift
        case .watch:      .cyan
        case .signalLight: .yellow
        case .shortcuts:  .gray
```

Find the `section` switch:

```swift
        case .general, .setup, .display, .sound, .appearance, .watch: .system
        case .shortcuts, .lab:                                        .advanced
```

Add `signalLight` to the `.system` group:

```swift
        case .general, .setup, .display, .sound, .appearance, .watch, .signalLight: .system
        case .shortcuts, .lab:                                                      .advanced
```

- [ ] **Step 2: Route the new tab to its pane**

Find `SettingsView.detailView`'s switch:

```swift
            case .watch:
                WatchSettingsPane(model: model)
            case .shortcuts:
```

Add a case:

```swift
            case .watch:
                WatchSettingsPane(model: model)
            case .signalLight:
                SignalLightSettingsPane(model: model)
            case .shortcuts:
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manually verify in the running app**

Run: `zsh scripts/launch-dev-app.sh`

Open Settings and confirm:
- A new "Signal Light" row appears in the sidebar under the same section as "Watch", with a beacon icon.
- Selecting it shows the Device section (status "Not connected", a "Scan" button) and the Modes section (four rows: Needs Approval, Needs Answer, Running, Idle — each with a segmented Solid/Blink/Cycle/Breathe picker, three color toggles, and a Test button; the interval stepper is hidden when Solid is selected and appears for the other three).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandApp/Views/SettingsView.swift
git commit -m "feat: add Signal Light tab to Settings"
```

---

### Task 7: Bluetooth usage-description strings for packaged and dev builds

**Files:**
- Modify: `scripts/package-app.sh`
- Modify: `scripts/launch-dev-app.sh`

**Interfaces:** None — plist string additions only, no code interfaces.

- [ ] **Step 1: Add the key to the packaged-app Info.plist**

In `scripts/package-app.sh`, find:

```
    <key>NSAppleEventsUsageDescription</key>
    <string>Open Island needs automation access to focus Terminal and iTerm sessions for jump-back.</string>
    <key>NSHighResolutionCapable</key>
```

Replace with:

```
    <key>NSAppleEventsUsageDescription</key>
    <string>Open Island needs automation access to focus Terminal and iTerm sessions for jump-back.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Open Island uses Bluetooth to connect to your optional signal light device.</string>
    <key>NSHighResolutionCapable</key>
```

- [ ] **Step 2: Add the same key to the dev-app Info.plist**

In `scripts/launch-dev-app.sh`, find:

```
    <key>NSAppleEventsUsageDescription</key>
    <string>Open Island needs automation access to focus Terminal and iTerm sessions for jump-back.</string>
    <key>NSHighResolutionCapable</key>
```

Replace with:

```
    <key>NSAppleEventsUsageDescription</key>
    <string>Open Island needs automation access to focus Terminal and iTerm sessions for jump-back.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Open Island uses Bluetooth to connect to your optional signal light device.</string>
    <key>NSHighResolutionCapable</key>
```

- [ ] **Step 3: Validate both scripts still produce valid plists**

Run: `zsh scripts/launch-dev-app.sh`
Expected: script completes without error (it runs `plutil`-style validation implicitly by launching the app; if the app launches normally, the plist was valid). If it fails, check for a stray or missing `<key>`/`<string>` tag around the new entry.

- [ ] **Step 4: Commit**

```bash
git add scripts/package-app.sh scripts/launch-dev-app.sh
git commit -m "chore: add Bluetooth usage description for signal light support"
```

---

### Task 8: End-to-end manual verification with the real device

**Files:** None — verification only, no code changes.

**Interfaces:** None.

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all tests PASS, including the new `SignalLightBucketResolverTests` and `SignalLightCommandEncoderTests` from Task 1.

- [ ] **Step 2: Pair with the real board**

Run: `zsh scripts/launch-dev-app.sh`, open Settings → Signal Light, click "Scan", and connect to the ESP32-C3 board (flashed with the updated firmware from Task 2). Confirm the status badge shows "Connected" with the device name.

- [ ] **Step 3: Verify state-driven behavior**

With a real or demo agent session, drive it through each phase and confirm the physical light follows within roughly a second of each transition, using whatever effect is currently configured for that bucket:
- Trigger a permission request (`waitingForApproval`) → light shows the `needsApproval` effect.
- Answer or dismiss it, then trigger a question prompt (`waitingForAnswer`) → light shows the `needsAnswer` effect.
- Let the session run with no pending approval/question (`running`) → light shows the `running` effect.
- Let all sessions complete / close them all → light shows the `idle` effect.

- [ ] **Step 4: Verify configuration changes take effect**

In Settings → Signal Light → Modes, change the `running` bucket's effect from Blink/Yellow to Breathe/Red+Green, click "Test", and confirm the physical light immediately reflects the new effect. Trigger a real running session afterward and confirm it now uses the updated effect (not the old default).

- [ ] **Step 5: Verify auto-reconnect**

Power-cycle the ESP32-C3 board (or move it out of range and back) while the app is running. Confirm the status badge transitions to "Not connected" and then back to "Connected" without any manual action, and that the light resyncs to the current bucket's effect once reconnected.

- [ ] **Step 6: Verify permission denial handling**

If possible, revoke Bluetooth permission for the app in System Settings → Privacy & Security → Bluetooth, relaunch, and confirm the Settings pane shows the "permission needed" banner with a working "Open Bluetooth Settings" button instead of crashing or silently failing.

No commit for this task — it's verification only. If any step fails, go back to the relevant earlier task, fix it, and re-run this task's steps from the top.
