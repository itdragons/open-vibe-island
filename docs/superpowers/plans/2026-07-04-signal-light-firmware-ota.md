# Signal Light BLE Firmware OTA — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user flash new ESP32-C3 firmware onto the connected signal-light device over BLE from the Signal Light settings pane, using the OTA protocol already implemented in `led.ino`.

**Architecture:** The firmware gains one read-only characteristic exposing its version string (no changes to the existing OTA protocol). `SignalLightCoordinator` discovers the OTA and version characteristics alongside the existing command characteristic, and forwards the relevant CoreBluetooth delegate callbacks to a new `SignalLightFirmwareUpdater`, which owns the chunked-transfer state machine independent of BLE session plumbing. `SignalLightSettingsPane` gains a new "Firmware" section driving that updater.

**Tech Stack:** Swift 6.2, SwiftUI, CoreBluetooth (macOS 14+), Arduino/ESP32 C++ (`Update.h`).

## Global Constraints

- Do not use TDD for this work — write the implementation directly, no failing-test-first steps. (Explicit user instruction; also consistent with this codebase's existing convention that CoreBluetooth-touching code in `OpenIslandApp` — e.g. `SignalLightCoordinator` — has no automated tests and is verified manually instead.)
- Minimal-footprint principle from the original signal-light design carries over: firmware changes are additive only, no existing command/mode/OTA logic in `led.ino` is modified.
- All existing named BLE commands, OTA commands, and effect behavior must keep working unchanged.
- Follow existing project conventions: `.withResponse` for signal light BLE writes (see commit `1ea57ac`), `@Observable`/`@ObservationIgnored` patterns already used in `SignalLightCoordinator.swift`, and the localization pattern of `lang.t("settings.signalLight.<key>")` with matching entries in all three `Localizable.strings` files.
- Design spec: `docs/superpowers/specs/2026-07-04-signal-light-firmware-ota-design.md`. Refer to it for the full rationale — this plan implements it as-is.

---

### Task 1: Firmware — expose firmware version over BLE

**Files:**
- Modify: `signal-light/led/config.h`
- Modify: `signal-light/led/led.ino:100-158` (inside `setup()`)

**Interfaces:**
- Produces: `FIRMWARE_VERSION` (String constant), `INFO_CHARACTERISTIC_UUID` (macro), used only by this task — the Swift side identifies this characteristic by the literal UUID string `"77697364-6f6d-6761-7264-656e00000005"`, not by including the header.

- [ ] **Step 1: Add the version constant and characteristic UUID to `config.h`**

In `signal-light/led/config.h`, replace:

```cpp
#define OTA_DATA_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000004"

#endif // CONFIG_H
```

with:

```cpp
#define OTA_DATA_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000004"

// -----------------------------------------------------------------------------
// 固件版本 (Firmware Version) — bump manually before compiling a new build
// -----------------------------------------------------------------------------
const String FIRMWARE_VERSION = "1.0.0";
#define INFO_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000005"

#endif // CONFIG_H
```

- [ ] **Step 2: Add the read-only INFO characteristic in `led.ino`'s `setup()`**

In `signal-light/led/led.ino`, find this existing block (around line 143):

```cpp
  BLECharacteristic *otaDataCharacteristic = service->createCharacteristic(
    OTA_DATA_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  otaDataCharacteristic->setCallbacks(new OtaDataCallback());

  service->start();
```

Replace it with:

```cpp
  BLECharacteristic *otaDataCharacteristic = service->createCharacteristic(
    OTA_DATA_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  otaDataCharacteristic->setCallbacks(new OtaDataCallback());

  BLECharacteristic *infoCharacteristic = service->createCharacteristic(
    INFO_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ
  );
  infoCharacteristic->setValue(FIRMWARE_VERSION.c_str());

  service->start();
```

- [ ] **Step 3: Verify it compiles**

If `arduino-cli` is available, run from `signal-light/led/`:
```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3 .
```
Expected: compiles with no errors (warnings about `esp32:esp32` core version are fine).

If `arduino-cli` isn't installed, open `led.ino` in the Arduino IDE and use Sketch → Verify/Compile instead. Either way, confirm before moving on — this task doesn't get flashed to a real board until Task 6.

- [ ] **Step 4: Commit**

```bash
git add signal-light/led/config.h signal-light/led/led.ino
git commit -m "feat(firmware): expose firmware version over a read-only BLE characteristic"
```

---

### Task 2: `SignalLightFirmwareUpdater` — OTA transfer state machine

**Files:**
- Create: `Sources/OpenIslandApp/SignalLightFirmwareUpdater.swift`

**Interfaces:**
- Produces (consumed by Task 3 and Task 5):
  - `enum SignalLightFirmwareUpdateState: Equatable { case idle, transferring(sent: Int, total: Int), finishing, succeeded, failed(String) }`
  - `enum SignalLightFirmwareUpdateError: LocalizedError` with case `.notReady` (used by Task 3's "not connected" guard)
  - `@MainActor @Observable final class SignalLightFirmwareUpdater`:
    - `private(set) var state: SignalLightFirmwareUpdateState`
    - `func beginUpdate(fileURL: URL, peripheral: CBPeripheral, otaControlCharacteristic: CBCharacteristic, otaDataCharacteristic: CBCharacteristic)`
    - `func failImmediately(_ reason: String)`
    - `func cancel()`
    - `func handleUnexpectedDisconnect()`
    - `func handleWriteResponse(for characteristic: CBCharacteristic, error: Error?)`
    - `func handleControlStatusUpdate(_ text: String)`

- [ ] **Step 1: Write the full file**

Create `Sources/OpenIslandApp/SignalLightFirmwareUpdater.swift`:

```swift
import Foundation
@preconcurrency import CoreBluetooth
import Observation

/// Progress/outcome of an in-flight (or just-finished) BLE firmware flash.
enum SignalLightFirmwareUpdateState: Equatable {
    case idle
    case transferring(sent: Int, total: Int)
    case finishing
    case succeeded
    case failed(String)
}

enum SignalLightFirmwareUpdateError: LocalizedError {
    case notReady
    case disconnected
    case timedOut
    case firmwareRejected(String)
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .notReady: "Signal light is not connected"
        case .disconnected: "Device disconnected"
        case .timedOut: "Device did not respond in time"
        case .firmwareRejected(let status): status
        case .unreadableFile: "Could not read the firmware file"
        }
    }
}

/// Drives a BLE OTA firmware flash over the signal light's existing
/// `OTA_CONTROL`/`OTA_DATA` characteristics (see `signal-light/led/led.ino`).
/// Owns only the transfer state machine; `SignalLightCoordinator` owns the
/// actual CoreBluetooth session and forwards it the delegate callbacks this
/// type needs.
@MainActor
@Observable
final class SignalLightFirmwareUpdater {
    private(set) var state: SignalLightFirmwareUpdateState = .idle

    @ObservationIgnored private var otaControlCharacteristic: CBCharacteristic?
    @ObservationIgnored private var otaDataCharacteristic: CBCharacteristic?
    @ObservationIgnored private var chunkSize = 180
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWrite: (continuation: CheckedContinuation<Void, Error>, timeoutTask: Task<Void, Never>)?
    @ObservationIgnored private var pendingStatus: (continuation: CheckedContinuation<String, Error>, timeoutTask: Task<Void, Never>)?

    /// Starts flashing `fileURL` to the peripheral. No-ops if a transfer is
    /// already in progress; safe to call again after `.succeeded`/`.failed`.
    func beginUpdate(
        fileURL: URL,
        peripheral: CBPeripheral,
        otaControlCharacteristic: CBCharacteristic,
        otaDataCharacteristic: CBCharacteristic
    ) {
        switch state {
        case .transferring, .finishing:
            return
        default:
            break
        }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            state = .failed(SignalLightFirmwareUpdateError.unreadableFile.errorDescription ?? "Could not read file")
            return
        }

        self.otaControlCharacteristic = otaControlCharacteristic
        self.otaDataCharacteristic = otaDataCharacteristic
        chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        state = .transferring(sent: 0, total: data.count)

        transferTask = Task { [weak self] in
            await self?.runTransfer(peripheral: peripheral, data: data)
        }
    }

    /// Immediately marks the update as failed without starting a transfer —
    /// used by the coordinator when a flash is requested while disconnected.
    func failImmediately(_ reason: String) {
        guard case .idle = state else { return }
        state = .failed(reason)
    }

    /// Best-effort abort: tells the firmware to abandon the OTA write and
    /// unblocks whatever the transfer loop is currently awaiting.
    func cancel() {
        guard transferTask != nil else { return }

        if let otaControlCharacteristic, let peripheral = otaControlCharacteristic.service?.peripheral {
            peripheral.writeValue(Data("OTA_ABORT".utf8), for: otaControlCharacteristic, type: .withResponse)
        }
        failPending(with: CancellationError())
        transferTask?.cancel()
    }

    /// Called by the coordinator when the peripheral disconnects
    /// unexpectedly (not the reboot-after-success case, which finishes the
    /// transfer task before the disconnect happens).
    func handleUnexpectedDisconnect() {
        guard transferTask != nil else { return }
        failPending(with: SignalLightFirmwareUpdateError.disconnected)
        transferTask?.cancel()
    }

    /// Forwarded from `SignalLightCoordinator.peripheral(_:didWriteValueFor:error:)`.
    func handleWriteResponse(for characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === otaControlCharacteristic || characteristic === otaDataCharacteristic else { return }
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        pending.timeoutTask.cancel()
        if let error {
            pending.continuation.resume(throwing: error)
        } else {
            pending.continuation.resume()
        }
    }

    /// Forwarded from `SignalLightCoordinator.peripheral(_:didUpdateValueFor:error:)`
    /// for the `OTA_CONTROL` characteristic — this is how the firmware reports
    /// `OTA_BEGIN`/`OTA_END` success or failure (see `setOtaStatus` in `led.ino`).
    func handleControlStatusUpdate(_ text: String) {
        guard let pending = pendingStatus else { return }
        pendingStatus = nil
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: text)
    }

    private func failPending(with error: Error) {
        if let pending = pendingWrite {
            pendingWrite = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        if let pending = pendingStatus {
            pendingStatus = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private func runTransfer(peripheral: CBPeripheral, data: Data) async {
        do {
            let beginStatus = try await sendControlCommandAndAwaitStatus(
                "OTA_BEGIN:\(data.count)",
                on: peripheral,
                timeoutSeconds: 10
            )
            guard beginStatus.uppercased().contains("OK") else {
                throw SignalLightFirmwareUpdateError.firmwareRejected(beginStatus)
            }

            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, data.count)
                try await writeChunkAndAwaitAck(data.subdata(in: offset..<end), on: peripheral)
                offset = end
                state = .transferring(sent: offset, total: data.count)
            }

            state = .finishing
            let endStatus = try await sendControlCommandAndAwaitStatus("OTA_END", on: peripheral, timeoutSeconds: 15)
            guard endStatus.uppercased().contains("OK") else {
                throw SignalLightFirmwareUpdateError.firmwareRejected(endStatus)
            }

            state = .succeeded
        } catch is CancellationError {
            state = .idle
        } catch let error as SignalLightFirmwareUpdateError {
            state = .failed(error.errorDescription ?? "Firmware update failed")
        } catch {
            state = .failed(error.localizedDescription)
        }

        reset()
    }

    private func writeChunkAndAwaitAck(_ chunk: Data, on peripheral: CBPeripheral) async throws {
        guard let otaDataCharacteristic else {
            throw SignalLightFirmwareUpdateError.notReady
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.timeoutPendingWrite()
            }
            pendingWrite = (continuation, timeoutTask)
            peripheral.writeValue(chunk, for: otaDataCharacteristic, type: .withResponse)
        }
    }

    private func sendControlCommandAndAwaitStatus(
        _ text: String,
        on peripheral: CBPeripheral,
        timeoutSeconds: UInt64
    ) async throws -> String {
        guard let otaControlCharacteristic else {
            throw SignalLightFirmwareUpdateError.notReady
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.timeoutPendingStatus()
            }
            pendingStatus = (continuation, timeoutTask)
            peripheral.writeValue(Data(text.utf8), for: otaControlCharacteristic, type: .withResponse)
        }
    }

    private func timeoutPendingWrite() {
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        pending.continuation.resume(throwing: SignalLightFirmwareUpdateError.timedOut)
    }

    private func timeoutPendingStatus() {
        guard let pending = pendingStatus else { return }
        pendingStatus = nil
        pending.continuation.resume(throwing: SignalLightFirmwareUpdateError.timedOut)
    }

    private func reset() {
        otaControlCharacteristic = nil
        otaDataCharacteristic = nil
        transferTask = nil
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build
```
Expected: builds with no errors. (This file has no callers yet, so it just needs to type-check standalone.)

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenIslandApp/SignalLightFirmwareUpdater.swift
git commit -m "feat: add SignalLightFirmwareUpdater BLE OTA transfer state machine"
```

---

### Task 3: Wire `SignalLightCoordinator` to the OTA/version characteristics

**Files:**
- Modify: `Sources/OpenIslandApp/SignalLightCoordinator.swift`

**Interfaces:**
- Consumes: `SignalLightFirmwareUpdater` and `SignalLightFirmwareUpdateError` from Task 2 (exact names above).
- Produces (consumed by Task 5):
  - `coordinator.firmwareVersion: String?`
  - `coordinator.firmwareUpdater: SignalLightFirmwareUpdater`
  - `coordinator.beginFirmwareUpdate(fileURL: URL)`
  - `coordinator.cancelFirmwareUpdate()`

- [ ] **Step 1: Add UUID constants and stored properties**

In `Sources/OpenIslandApp/SignalLightCoordinator.swift`, replace:

```swift
    private static let serviceUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000001")
    private static let commandCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000002")
    private static let pairedPeripheralIDDefaultsKey = "signalLight.pairedPeripheralID"

    private(set) var status: SignalLightConnectionStatus = .disconnected
    private(set) var discoveredDevices: [SignalLightDiscoveredDevice] = []
```

with:

```swift
    private static let serviceUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000001")
    private static let commandCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000002")
    private static let otaControlCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000003")
    private static let otaDataCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000004")
    private static let infoCharacteristicUUID = CBUUID(string: "77697364-6f6d-6761-7264-656e00000005")
    private static let pairedPeripheralIDDefaultsKey = "signalLight.pairedPeripheralID"

    private(set) var status: SignalLightConnectionStatus = .disconnected
    private(set) var discoveredDevices: [SignalLightDiscoveredDevice] = []
    private(set) var firmwareVersion: String?
    let firmwareUpdater = SignalLightFirmwareUpdater()
```

Then replace:

```swift
    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var commandCharacteristic: CBCharacteristic?
    @ObservationIgnored private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
```

with:

```swift
    @ObservationIgnored private var centralManager: CBCentralManager?
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var commandCharacteristic: CBCharacteristic?
    @ObservationIgnored private var otaControlCharacteristic: CBCharacteristic?
    @ObservationIgnored private var otaDataCharacteristic: CBCharacteristic?
    @ObservationIgnored private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
```

- [ ] **Step 2: Add `beginFirmwareUpdate`/`cancelFirmwareUpdate`**

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

    private func attemptAutoReconnect() {
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

    func beginFirmwareUpdate(fileURL: URL) {
        guard let peripheral = connectedPeripheral,
              let otaControlCharacteristic,
              let otaDataCharacteristic,
              peripheral.state == .connected else {
            firmwareUpdater.failImmediately(SignalLightFirmwareUpdateError.notReady.errorDescription ?? "Not connected")
            return
        }
        firmwareUpdater.beginUpdate(
            fileURL: fileURL,
            peripheral: peripheral,
            otaControlCharacteristic: otaControlCharacteristic,
            otaDataCharacteristic: otaDataCharacteristic
        )
    }

    func cancelFirmwareUpdate() {
        firmwareUpdater.cancel()
    }

    private func attemptAutoReconnect() {
```

- [ ] **Step 3: Clear OTA state on disconnect**

Replace:

```swift
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            connectedPeripheral = nil
            commandCharacteristic = nil
            status = .disconnected
            attemptAutoReconnect()
        }
    }
```

with:

```swift
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            connectedPeripheral = nil
            commandCharacteristic = nil
            otaControlCharacteristic = nil
            otaDataCharacteristic = nil
            firmwareVersion = nil
            firmwareUpdater.handleUnexpectedDisconnect()
            status = .disconnected
            attemptAutoReconnect()
        }
    }
```

- [ ] **Step 4: Discover the new characteristics and forward OTA delegate callbacks**

Replace:

```swift
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

with:

```swift
extension SignalLightCoordinator: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                return
            }
            peripheral.discoverCharacteristics(
                [Self.commandCharacteristicUUID, Self.otaControlCharacteristicUUID, Self.otaDataCharacteristicUUID, Self.infoCharacteristicUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let characteristics = service.characteristics else {
                return
            }

            for characteristic in characteristics {
                switch characteristic.uuid {
                case Self.commandCharacteristicUUID:
                    commandCharacteristic = characteristic
                case Self.otaControlCharacteristicUUID:
                    otaControlCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case Self.otaDataCharacteristicUUID:
                    otaDataCharacteristic = characteristic
                case Self.infoCharacteristicUUID:
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }

            guard commandCharacteristic != nil else {
                return
            }
            status = .connected(name: peripheral.name ?? "Signal Light")
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

- [ ] **Step 5: Build**

```bash
swift build
```
Expected: builds with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenIslandApp/SignalLightCoordinator.swift
git commit -m "feat: discover signal light OTA/version characteristics and drive firmware updater"
```

---

### Task 4: Localization strings

**Files:**
- Modify: `Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hant.lproj/Localizable.strings`

**Interfaces:**
- Produces: the `settings.signalLight.firmware*` keys below, consumed by Task 5. Reuses the existing `settings.general.cancel` key for both Cancel buttons (already present in all three files) — no new "cancel" key is added.

- [ ] **Step 1: Append to `en.lproj/Localizable.strings`**

After the existing `"settings.signalLight.bucket.idle" = "Idle";` line, add:

```
"settings.signalLight.firmware" = "Firmware";
"settings.signalLight.firmwareNeedsConnection" = "Connect a device first.";
"settings.signalLight.firmwareVersion" = "Firmware Version";
"settings.signalLight.firmwareVersionUnknown" = "Unknown";
"settings.signalLight.firmwareChooseFile" = "Choose Firmware File…";
"settings.signalLight.firmwareChangeFile" = "Change";
"settings.signalLight.firmwareFlash" = "Flash Firmware";
"settings.signalLight.firmwareConfirmTitle" = "Flash this firmware?";
"settings.signalLight.firmwareConfirmMessage" = "Don't disconnect Bluetooth or quit the app while flashing. This can take 1-3 minutes.";
"settings.signalLight.firmwareConfirmAction" = "Flash";
"settings.signalLight.firmwareSucceeded" = "Flashed successfully. Device is restarting…";
"settings.signalLight.firmwareFailedPrefix" = "Flash failed: ";
"settings.signalLight.firmwareFailedReassurance" = "The signal light is still running its previous firmware — you can try again.";
```

- [ ] **Step 2: Append to `zh-Hans.lproj/Localizable.strings`**

After the existing `"settings.signalLight.bucket.idle" = "空闲";` line, add:

```
"settings.signalLight.firmware" = "固件";
"settings.signalLight.firmwareNeedsConnection" = "请先连接设备。";
"settings.signalLight.firmwareVersion" = "固件版本";
"settings.signalLight.firmwareVersionUnknown" = "未知";
"settings.signalLight.firmwareChooseFile" = "选择固件文件…";
"settings.signalLight.firmwareChangeFile" = "更换";
"settings.signalLight.firmwareFlash" = "刷入固件";
"settings.signalLight.firmwareConfirmTitle" = "确定要刷入固件吗？";
"settings.signalLight.firmwareConfirmMessage" = "刷写期间请勿断开蓝牙或关闭 App，大约需要 1-3 分钟。";
"settings.signalLight.firmwareConfirmAction" = "刷入";
"settings.signalLight.firmwareSucceeded" = "刷写成功，设备正在重启…";
"settings.signalLight.firmwareFailedPrefix" = "刷写失败：";
"settings.signalLight.firmwareFailedReassurance" = "信号灯仍在运行之前的固件，可以重试。";
```

- [ ] **Step 3: Append to `zh-Hant.lproj/Localizable.strings`**

After the existing `"settings.signalLight.bucket.idle" = "閒置";` line, add:

```
"settings.signalLight.firmware" = "韌體";
"settings.signalLight.firmwareNeedsConnection" = "請先連接裝置。";
"settings.signalLight.firmwareVersion" = "韌體版本";
"settings.signalLight.firmwareVersionUnknown" = "未知";
"settings.signalLight.firmwareChooseFile" = "選擇韌體檔案…";
"settings.signalLight.firmwareChangeFile" = "更換";
"settings.signalLight.firmwareFlash" = "燒錄韌體";
"settings.signalLight.firmwareConfirmTitle" = "確定要燒錄韌體嗎？";
"settings.signalLight.firmwareConfirmMessage" = "燒錄期間請勿中斷藍牙或關閉 App，大約需要 1-3 分鐘。";
"settings.signalLight.firmwareConfirmAction" = "燒錄";
"settings.signalLight.firmwareSucceeded" = "燒錄成功，裝置正在重新啟動…";
"settings.signalLight.firmwareFailedPrefix" = "燒錄失敗：";
"settings.signalLight.firmwareFailedReassurance" = "信號燈仍在執行先前的韌體，可以重試。";
```

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenIslandApp/Resources/*/Localizable.strings
git commit -m "feat: localize signal light firmware update strings"
```

---

### Task 5: Firmware section in `SignalLightSettingsPane`

**Files:**
- Modify: `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`

**Interfaces:**
- Consumes: `model.signalLight.firmwareVersion`, `model.signalLight.firmwareUpdater.state` (`SignalLightFirmwareUpdateState`), `model.signalLight.beginFirmwareUpdate(fileURL:)`, `model.signalLight.cancelFirmwareUpdate()` (all from Task 3), and the localization keys from Task 4.

- [ ] **Step 1: Add the `UniformTypeIdentifiers` import and local state**

Replace:

```swift
import AppKit
import SwiftUI
import OpenIslandCore

struct SignalLightSettingsPane: View {
    var model: AppModel

    private var lang: LanguageManager { model.lang }

    var body: some View {
        Form {
            deviceSection
            modesSection
        }
        .formStyle(.grouped)
        .navigationTitle(lang.t("settings.tab.signalLight"))
    }
```

with:

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenIslandCore

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

- [ ] **Step 2: Disable "Disconnect" during a transfer**

Replace:

```swift
            case .connected:
                Button(lang.t("settings.signalLight.disconnect"), role: .destructive) {
                    model.signalLight.disconnect()
                }
```

with:

```swift
            case .connected:
                Button(lang.t("settings.signalLight.disconnect"), role: .destructive) {
                    model.signalLight.disconnect()
                }
                .disabled(isTransferring)
```

- [ ] **Step 3: Disable each mode row's "Test" button during a transfer**

Replace:

```swift
    @ViewBuilder
    private var modesSection: some View {
        Section {
            ForEach(SignalLightBucket.allCases, id: \.self) { bucket in
                SignalLightModeRow(
                    title: bucketTitle(bucket),
                    lang: lang,
                    effect: Binding(
                        get: { model.signalLightEffects[bucket] ?? .defaultEffect(for: bucket) },
                        set: { model.signalLightEffects[bucket] = $0 }
                    ),
                    onTest: { effect in
                        model.signalLight.send(effect)
                    }
                )
            }
```

with:

```swift
    @ViewBuilder
    private var modesSection: some View {
        Section {
            ForEach(SignalLightBucket.allCases, id: \.self) { bucket in
                SignalLightModeRow(
                    title: bucketTitle(bucket),
                    lang: lang,
                    effect: Binding(
                        get: { model.signalLightEffects[bucket] ?? .defaultEffect(for: bucket) },
                        set: { model.signalLightEffects[bucket] = $0 }
                    ),
                    isTestDisabled: isTransferring,
                    onTest: { effect in
                        model.signalLight.send(effect)
                    }
                )
            }
```

- [ ] **Step 4: Add `isTestDisabled` to `SignalLightModeRow`**

Replace:

```swift
private struct SignalLightModeRow: View {
    let title: String
    let lang: LanguageManager
    @Binding var effect: SignalLightEffect
    let onTest: (SignalLightEffect) -> Void
```

with:

```swift
private struct SignalLightModeRow: View {
    let title: String
    let lang: LanguageManager
    @Binding var effect: SignalLightEffect
    let isTestDisabled: Bool
    let onTest: (SignalLightEffect) -> Void
```

Then replace:

```swift
                Button(lang.t("settings.signalLight.test")) {
                    onTest(effect)
                }
                .layoutPriority(1)
```

with:

```swift
                Button(lang.t("settings.signalLight.test")) {
                    onTest(effect)
                }
                .layoutPriority(1)
                .disabled(isTestDisabled)
```

- [ ] **Step 5: Add the firmware section and its helpers**

At the end of the main `SignalLightSettingsPane` struct, immediately after the closing brace of `bucketTitle(_:)` and before the struct's own closing brace, add:

```swift

    // MARK: Firmware

    @ViewBuilder
    private var firmwareSection: some View {
        Section(lang.t("settings.signalLight.firmware")) {
            if case .connected = model.signalLight.status {
                firmwareVersionRow
                firmwareFilePickerRow
                firmwareActionRow
            } else {
                Text(lang.t("settings.signalLight.firmwareNeedsConnection"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var firmwareVersionRow: some View {
        HStack {
            Text(lang.t("settings.signalLight.firmwareVersion"))
            Spacer()
            Text(model.signalLight.firmwareVersion ?? lang.t("settings.signalLight.firmwareVersionUnknown"))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var firmwareFilePickerRow: some View {
        HStack {
            if let selectedFirmwareURL {
                Text(selectedFirmwareURL.lastPathComponent)
                Spacer()
                Button(lang.t("settings.signalLight.firmwareChangeFile")) {
                    presentFirmwarePicker()
                }
                .disabled(isTransferring)
            } else {
                Button(lang.t("settings.signalLight.firmwareChooseFile")) {
                    presentFirmwarePicker()
                }
                .disabled(isTransferring)
            }
        }
    }

    @ViewBuilder
    private var firmwareActionRow: some View {
        switch model.signalLight.firmwareUpdater.state {
        case .idle:
            Button(lang.t("settings.signalLight.firmwareFlash")) {
                isShowingFlashConfirmation = true
            }
            .disabled(selectedFirmwareURL == nil)
            .confirmationDialog(
                lang.t("settings.signalLight.firmwareConfirmTitle"),
                isPresented: $isShowingFlashConfirmation
            ) {
                Button(lang.t("settings.signalLight.firmwareConfirmAction"), role: .destructive) {
                    if let selectedFirmwareURL {
                        model.signalLight.beginFirmwareUpdate(fileURL: selectedFirmwareURL)
                    }
                }
                Button(lang.t("settings.general.cancel"), role: .cancel) {}
            } message: {
                Text(lang.t("settings.signalLight.firmwareConfirmMessage"))
            }

        case .transferring(let sent, let total):
            firmwareProgressRow(sent: sent, total: total)

        case .finishing:
            firmwareProgressRow(sent: nil, total: nil)

        case .succeeded:
            Text(lang.t("settings.signalLight.firmwareSucceeded"))
                .foregroundStyle(.green)

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("settings.signalLight.firmwareFailedPrefix") + reason)
                    .foregroundStyle(.red)
                Text(lang.t("settings.signalLight.firmwareFailedReassurance"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func firmwareProgressRow(sent: Int?, total: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sent, let total, total > 0 {
                ProgressView(value: Double(sent), total: Double(total))
                Text("\(formattedByteCount(sent)) / \(formattedByteCount(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Button(lang.t("settings.general.cancel"), role: .destructive) {
                model.signalLight.cancelFirmwareUpdate()
            }
        }
    }

    private func presentFirmwarePicker() {
        let panel = NSOpenPanel()
        if let binType = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [binType]
        }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedFirmwareURL = url
        }
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
```

- [ ] **Step 6: Build**

```bash
swift build
```
Expected: builds with no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift
git commit -m "feat: add firmware update UI to Signal Light settings"
```

---

### Task 6: End-to-end manual verification with a physical board

This task has no code changes — it's the manual verification pass called for in the design spec's testing plan, and requires a physical ESP32-C3 signal-light board plus a USB cable for the baseline flash.

**Files:** none (verification only)

- [ ] **Step 1: Compile and flash a baseline firmware via USB**

In Arduino IDE, open `signal-light/led/led.ino`, confirm `FIRMWARE_VERSION` reads `"1.0.0"` (from Task 1), compile, and flash to the board over USB as usual.

- [ ] **Step 2: Confirm version display**

```bash
zsh scripts/launch-dev-app.sh
```
In Settings → Signal Light, connect to the device. Confirm the new "Firmware" section shows `Firmware Version: 1.0.0`.

- [ ] **Step 3: Flash a new version over BLE**

Bump `FIRMWARE_VERSION` to `"1.0.1"` in `config.h` and change one visibly-testable behavior (e.g. `animateWorking`'s breathe period in `led.ino`). Recompile and use Arduino IDE's "Export Compiled Binary" to produce a `.bin`. In the app, use "Choose Firmware File…" to select it, then "Flash Firmware", confirm the dialog, and watch the transfer:
- Progress bar advances and the other Signal Light controls (Disconnect, Test buttons) are disabled during the transfer.
- On completion: success message, device restarts, app auto-reconnects, and the Firmware Version row updates to `1.0.1`.

- [ ] **Step 4: Cancel mid-transfer**

Start another flash (of the same or a different `.bin`) and click "Cancel" partway through. Confirm the device keeps running normally without needing a manual restart, and that starting a new flash afterward works.

- [ ] **Step 5: Simulate an unexpected disconnect**

Start a flash and power off the board (or move it out of BLE range) partway through. Confirm the app shows a failure message referencing the disconnect, and that powering the board back on shows it still running its previous firmware.

- [ ] **Step 6: Verify a corrupted file is rejected cleanly**

Take a valid `.bin`, truncate it (e.g. `head -c 1000 led.ino.bin > truncated.bin`), and try flashing it. Confirm the app surfaces an `OTA_END`/byte-count-mismatch failure message rather than hanging or crashing, and that the board is still running its previous firmware afterward.

No commit for this task — it's verification only. If any step surfaces a bug, fix it as a follow-up commit referencing the specific task/file it belongs to, then re-run the affected verification step.
