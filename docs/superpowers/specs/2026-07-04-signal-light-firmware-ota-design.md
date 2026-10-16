# Signal Light — BLE Firmware OTA Update — Design Spec

Status: Approved for planning
Date: 2026-07-04

## Summary

Add the ability to flash new ESP32-C3 firmware onto the signal-light device over Bluetooth, from the existing Signal Light settings pane, using the BLE OTA protocol the firmware already implements (`OTA_BEGIN`/`OTA_DATA`/`OTA_END`/`OTA_ABORT`/`OTA_STATUS` via `Update.h`). Today that protocol exists in `led.ino` but nothing on the client side uses it — updating firmware requires a USB cable. This closes that gap.

This builds on the original [2026-07-03 signal-light design](2026-07-03-signal-light-design.md), which explicitly deferred "in-app firmware OTA upload UI" as a non-goal. That non-goal is now in scope.

## Goals

1. Settings → Signal Light → see the currently connected device's firmware version.
2. Settings → Signal Light → pick a locally compiled `.bin` file and flash it to the connected device over BLE, with progress feedback, cancel support, and clear success/failure states.
3. Firmware stays safe to reflash: a failed or interrupted transfer never leaves the board unable to boot.

## Non-goals (this iteration)

- Compiling firmware. The user compiles/exports the `.bin` themselves (e.g. Arduino IDE "Export Compiled Binary"); the app only consumes an already-built binary file.
- Any remote firmware distribution (bundled resource, GitHub Releases, version-check-and-download). The file is always picked manually from local disk — matches the project's local-first principle and avoids standing up release/versioning infrastructure for a low-frequency, single-user hardware accessory.
- Automatic update checks or "new version available" prompts. There is a version display, but no comparison logic — the user decides when and what to flash.
- Enhancing `test_ble.py` with OTA support. This iteration is App-UI-only; the Python script is unaffected.
- Resuming an interrupted transfer. Firmware images here are small (a few hundred KB); a failed transfer is simply retried from scratch.
- write-without-response pipelining (faster but more complex/riskier transfer mode) — deferred; see Architecture for the chosen approach and why.

## Architecture

### Firmware (`signal-light/led/led.ino`, `signal-light/led/config.h`)

Firmware changes are limited to exposing a version string — the existing OTA protocol (`OTA_CONTROL`/`OTA_DATA` characteristics, `Update.h`-based flash writes) is unchanged.

`config.h` adds:
```cpp
const String FIRMWARE_VERSION = "1.0.0"; // bump manually before each firmware build
#define INFO_CHARACTERISTIC_UUID "77697364-6f6d-6761-7264-656e00000005"
```

`led.ino`'s `setup()` adds one new read-only characteristic alongside the existing ones:
```cpp
BLECharacteristic *infoCharacteristic = service->createCharacteristic(
  INFO_CHARACTERISTIC_UUID,
  BLECharacteristic::PROPERTY_READ
);
infoCharacteristic->setValue(FIRMWARE_VERSION.c_str());
```

No existing command, mode, or OTA branch is modified.

### OpenIslandApp

**`SignalLightCoordinator.swift`** (existing file, additive changes):
- Discovers three more characteristics on connect: `OTA_CONTROL_CHARACTERISTIC_UUID`, `OTA_DATA_CHARACTERISTIC_UUID` (both already defined in firmware, unused by the app until now), and the new `INFO_CHARACTERISTIC_UUID`.
- On discovering `INFO`, calls `peripheral.readValue(for:)`; the resulting value is exposed as `coordinator.firmwareVersion: String?`.
- Subscribes to notify on `OTA_CONTROL` (the channel firmware already uses for OTA status messages via `setOtaStatus`).
- Owns a `SignalLightFirmwareUpdater` instance and forwards it the CoreBluetooth delegate callbacks relevant to OTA: `peripheral(_:didWriteValueFor:)` (per-chunk write acknowledgment) and `peripheral(_:didUpdateValueFor:)` for the `OTA_CONTROL` characteristic (status/version messages). The coordinator remains the sole `CBPeripheralDelegate`; the updater is driven by method calls, not itself a delegate.

**New file `SignalLightFirmwareUpdater.swift`**:
- `@Observable final class SignalLightFirmwareUpdater`, holds all OTA business logic separately from BLE session plumbing.
- State: `.idle | .transferring(sent: Int, total: Int) | .finishing | .succeeded | .failed(String)`.
- `beginUpdate(fileURL: URL, peripheral: CBPeripheral, otaControl: CBCharacteristic, otaData: CBCharacteristic)`:
  1. Reads file bytes and total size.
  2. Writes `OTA_BEGIN:<size>` to `otaControl`.
  3. Computes chunk size from `peripheral.maximumWriteValueLength(for: .withResponse)`.
  4. Writes chunks to `otaData` sequentially, **write-with-response** — waits for each chunk's write-response callback before sending the next (chosen over write-without-response pipelining: simpler, matches the project's existing write-with-response convention for signal light BLE writes, and failure surfaces immediately per-chunk instead of only at the end; the multi-minute-vs-tens-of-seconds speed difference doesn't matter for an occasional manual flash). A 5-second per-chunk timeout fails the transfer if a write-response never arrives.
  5. Updates `sent` after each successful chunk; UI progress bar reflects it directly.
  6. After the last chunk, writes `OTA_END` to `otaControl` and waits for the firmware's notify response (success or failure text, via the already-existing `setOtaStatus`/notify mechanism).
- `cancel()`: best-effort writes `OTA_ABORT` to `otaControl`, stops the local chunk loop, resets to `.idle`.
- Does not implement retry or resume — a failed/cancelled transfer starts over from a fresh `beginUpdate` call.

### Views

**`SignalLightSettingsPane.swift`** (existing file, one new section):
- New "Firmware" `Section`, below the existing "Modes" section.
- **Disconnected**: single line of secondary text ("Connect a device first"), no controls.
- **Connected**:
  - Version row: current firmware version (from `coordinator.firmwareVersion`), or a loading/unknown state.
  - "Choose Firmware File…" button → `NSOpenPanel` filtered to `.bin`. After selection, shows filename + size and a "Change" button to re-pick.
  - "Flash Firmware" button (enabled only when a file is selected and the updater is `.idle`) → confirmation alert warning not to disconnect during the ~1-3 minute transfer.
  - While `.transferring`/`.finishing`: progress bar + `sent/total` byte readout, "Cancel" button. The "Choose Firmware File", "Disconnect", and the Modes section's "Test" buttons are all disabled during this window — a defensive measure to avoid any concurrent BLE write on the same connection while OTA is in flight, even though they use different characteristics.
  - `.succeeded`: success message noting the device is restarting; the coordinator's existing auto-reconnect handles the resulting disconnect as expected (not shown as an error), and firmware version is re-read on reconnect to confirm the new value.
  - `.failed(reason)`: error message with the reason, reassurance that the device is still running its previous firmware, and controls re-enabled for retry.

## Data flow

1. Coordinator connects → discovers command + OTA_CONTROL + OTA_DATA + INFO characteristics → reads INFO once → subscribes to OTA_CONTROL notify.
2. User picks a `.bin`, confirms flash → `SignalLightFirmwareUpdater.beginUpdate(...)`.
3. Updater: `OTA_BEGIN:<size>` → sequential write-with-response chunks to `OTA_DATA`, progress updates each chunk → `OTA_END`.
4. Firmware validates total bytes written; success or failure surfaces via the existing `OTA_CONTROL` notify channel.
5. Success → firmware restarts (existing 3s-delay logic, unchanged) → coordinator's existing disconnect/auto-reconnect flow reconnects → INFO re-read confirms new version.
6. Failure at any point (write timeout, disconnect, `OTA_END` size mismatch, user cancel) → updater state `.failed(reason)` or reset to `.idle` on cancel; firmware's inactive OTA partition means the previous firmware keeps running untouched — safe to retry immediately.

## Error handling

| Scenario | Behavior |
|---|---|
| BLE disconnects mid-transfer | Updater → `.failed("Device disconnected")`, stops sending; firmware never received `OTA_END` so it keeps booting the current firmware. |
| Single chunk write times out (5s) | Same as above — treated as a failed transfer, safe to retry. |
| `Update.begin` fails on firmware (e.g. insufficient flash) | Firmware's existing error path notifies via `OTA_CONTROL`; app surfaces that text verbatim. |
| `OTA_END` byte-count mismatch | Firmware's existing validation notifies failure via `OTA_CONTROL`; app shows "byte count mismatch, file may be incomplete." |
| User cancels mid-transfer | Best-effort `OTA_ABORT` sent; local state resets to `.idle` immediately without waiting for a response. |
| Firmware version read fails | Version row shows "Unknown"; no retry loop — the next reconnect will read it again naturally. |

No content validation is performed on the selected `.bin` beyond the file-picker's extension filter — this matches the project's existing practice of trusting local/manually-provided input and only validating at real boundaries.

## Testing plan

Following the existing convention that pure logic lives in `OpenIslandCore` with unit tests while CoreBluetooth-touching code in `OpenIslandApp` is verified manually (see `SignalLightCoordinator`, which has no automated tests today):

- `swift build` to confirm everything compiles.
- Manual, via `zsh scripts/launch-dev-app.sh`, with a physical ESP32-C3 board:
  1. Compile firmware once via Arduino IDE ("Export Compiled Binary") to confirm a `.bin` is produced from `led.ino`.
  2. Flash that baseline via USB; confirm the app shows the correct firmware version on connect.
  3. Bump `FIRMWARE_VERSION` and change one visibly-testable behavior (e.g. a mode's blink interval), recompile, then flash via the new in-app flow end-to-end: progress bar, controls disabled during transfer, post-success restart, auto-reconnect, updated version display.
  4. Cancel mid-transfer; confirm the device resumes normal operation on its existing firmware without needing a manual restart, and that a retry works.
  5. Simulate an unexpected disconnect mid-transfer (power off the board / move out of range); confirm the failure message appears and the board is still running its previous firmware afterward.
  6. Select a deliberately truncated `.bin`; confirm the `OTA_END` size-mismatch failure path displays correctly.

## Packaging note

No new Info.plist entries needed — `NSBluetoothAlwaysUsageDescription` already covers this feature; it uses the same BLE connection the app already has permission for.
