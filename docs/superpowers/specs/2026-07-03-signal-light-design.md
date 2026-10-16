# Signal Light BLE Integration — Design Spec

Status: Approved for planning
Date: 2026-07-03

## Summary

Add a physical BLE "signal light" (ESP32-C3 board, 3 independent LEDs: red/yellow/green — firmware at `signal-light/led/led.ino`) as a companion status indicator for Open Island. Two new Settings surfaces — device pairing and per-state light-effect configuration — plus a small runtime coordinator that watches aggregate agent-session state and drives the light accordingly.

This is a fork of an open-source project. **Minimal-footprint is a hard constraint**: new functionality must live in new files wherever possible, with the smallest possible touch points in shared files (`AppModel.swift`, `SettingsView.swift`, `led.ino`), so future upstream merges stay easy.

## Goals

1. Settings → scan for, connect to, and disconnect from a single BLE signal-light device.
2. Settings → configure what light effect represents each of 4 working-state buckets, freely choosing effect type + color(s) + speed (not limited to firmware-hardcoded modes).
3. Live linkage: as real agent sessions change state, the light automatically reflects it, with no user action required once configured and connected.

## Non-goals (this iteration)

- Multiple simultaneous signal-light devices (single device only).
- In-app firmware OTA upload UI (stays a manual `test_ble.py` / USB flash workflow).
- A dedicated "error/blocked" bucket — the app's session model has no such phase today; only the 4 phases that actually exist are addressed.
- Retry queues for dropped BLE writes — fail-open, matches the project's existing hooks philosophy.

## Minimal-footprint principle

- All new Swift types live in new files (`SignalLight*.swift`), not mixed into existing large files.
- `AppModel.swift` gets exactly one new stored property group (coordinator handle + last-sent bucket) and a small resolve-and-send block appended inside the existing `state`'s `didSet` — no restructuring of existing logic.
- `SettingsView.swift` gets one new `SettingsTab` case + one new pane type appended at the end of the file, following the existing `WatchSettingsPane` pattern — no changes to existing tabs/panes.
- `led.ino` / `config.h` get additive changes only: one new `LedMode` case, one new command branch in `handleCommand`, one new renderer function. No existing command, mode, or OTA logic is modified or removed.

## Architecture

### OpenIslandCore (pure, testable, no BLE/UI dependency)

New file `Sources/OpenIslandCore/SignalLight.swift`:

- `SignalLightEffectType`: `.solid | .blink | .cycle | .breathe`
- `SignalLightColor`: `.red | .yellow | .green`
- `SignalLightEffect`: `{ type: SignalLightEffectType, colors: [SignalLightColor], intervalMs: Int }` — Codable, Sendable, Equatable.
  - `colors` is ordered and holds 1–3 entries.
  - `intervalMs` is ignored by firmware when `type == .solid`.
- `SignalLightBucket`: `.needsApproval | .needsAnswer | .running | .idle` — Codable, Sendable, CaseIterable.
  - `idle` covers both "zero sessions" and "all sessions completed."
- `SignalLightBucketResolver.resolve(_ state: SessionState) -> SignalLightBucket` — pure function:
  1. Any session with phase `.waitingForApproval` → `.needsApproval`
  2. Else any session with phase `.waitingForAnswer` → `.needsAnswer`
  3. Else any session with phase `.running` → `.running`
  4. Else → `.idle`
- `SignalLightCommandEncoder`:
  - `encode(_ effect: SignalLightEffect) -> String` → `"EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>"`
    - `TYPE` ∈ `SOLID | BLINK | CYCLE | BREATHE`
    - `COLORS` is the ordered color list packed as letters, e.g. `RYG`, `Y`, `RG`
    - Example: `EFFECT:CYCLE:RYG:200`, `EFFECT:BLINK:Y:600`, `EFFECT:SOLID:G:0`
  - `decode(_ command: String) -> SignalLightEffect?` — inverse, used only by tests to validate round-tripping.

### OpenIslandApp

New file `Sources/OpenIslandApp/SignalLightCoordinator.swift`:

- `@Observable final class SignalLightCoordinator`, owns a `CBCentralManager` and the connected `CBPeripheral`.
- Responsibilities:
  - `startScan()` / `stopScan()` — discovers peripherals advertising the signal light's `SERVICE_UUID` (from `config.h`; mirrored as a constant here).
  - `connect(_:)` / `disconnect()` — standard CoreBluetooth connect/cancel flow.
  - Auto-reconnect: persists the last-connected peripheral's identifier (UserDefaults key `signalLight.pairedPeripheralID`); on launch and on unexpected disconnect, retries `CBCentralManager.retrievePeripherals(withIdentifiers:)` + `connect(_:)`.
  - `send(_ effect: SignalLightEffect)` — encodes via `SignalLightCommandEncoder` and writes to the command characteristic if connected; silently no-ops if not connected (fail-open — no queue).
  - On successful (re)connect, re-sends whatever `AppModel` currently reports as the resolved bucket's effect, so the light can't be left showing stale state from before a drop.
  - Exposed observable status: `.unauthorized | .poweredOff | .disconnected | .scanning | .connecting | .connected(name: String)`.

Touch point in `Sources/OpenIslandApp/AppModel.swift`:
- One new property: `let signalLight = SignalLightCoordinator()`.
- One new stored property: `@ObservationIgnored private var lastSentSignalLightBucket: SignalLightBucket?`.
- Inside the existing `state`'s `didSet` (AppModel.swift:47), append:
  ```swift
  let bucket = SignalLightBucketResolver.resolve(state)
  if bucket != lastSentSignalLightBucket {
      lastSentSignalLightBucket = bucket
      signalLight.send(signalLightEffects[bucket] ?? .defaultEffect(for: bucket))
  }
  ```
- `signalLightEffects: [SignalLightBucket: SignalLightEffect]` is a small computed/stored property on `AppModel`, backed by UserDefaults (JSON-encoded under key `signalLight.effects`), seeded with defaults on first read:
  - `.idle` → solid green
  - `.running` → yellow blink, 600ms
  - `.needsApproval` / `.needsAnswer` → red/yellow/green cycle, 200ms

New file `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`:
- `SignalLightSettingsPane`, structured like `WatchSettingsPane`:
  - **Device** section: connection status row (colored dot + label mirroring the `WatchSettingsPane` "Connected" row style), "Scan" button, discovered-device list with per-row "Connect" action, "Disconnect" button when connected, permission-denied banner with a "Open Bluetooth Settings" button when `CBManagerState` is `.unauthorized`.
  - **Modes** section: one row per `SignalLightBucket` (`needsApproval`, `needsAnswer`, `running`, `idle`), each with:
    - Effect type picker (Solid / Blink / Cycle / Breathe)
    - Color multi-select (Red / Yellow / Green, order-sensitive for Cycle)
    - Interval slider/stepper (hidden for Solid)
    - "Test" button that calls `model.signalLight.send(effect)` immediately, independent of real session state.

Touch point in `Sources/OpenIslandApp/Views/SettingsView.swift`:
- Add `case signalLight` to `SettingsTab` (icon: `"light.beacon.max.fill"` or similar, section: `.system`), and one `case .signalLight: SignalLightSettingsPane(model: model)` in `detailView`'s switch. No other existing tab/pane is touched.

### Firmware (`signal-light/led/led.ino`, `signal-light/led/config.h`)

- Add `MODE_CUSTOM_EFFECT` to the existing `LedMode` enum (additive).
- New state: `customEffectType` (enum: SOLID/BLINK/CYCLE/BREATHE), `customEffectColors` (up to 3 of `led_red`/`led_yellow`/`led_green`, ordered), `customEffectIntervalMs`.
- New branch in `handleCommand`, checked before the existing fixed-keyword branches: if `cmd` starts with `"EFFECT:"`, parse `TYPE:COLORS:INTERVAL`, populate the custom-effect state, and `startMode(MODE_CUSTOM_EFFECT)`. Malformed commands (bad type, empty colors, non-numeric interval) are ignored and the board stays in whatever mode it was already in — mirrors the existing "Unknown OTA command" handling style.
- New renderer `animateCustomEffect(nowMs)`, added alongside the existing `animateThinking`/`animateWorking`/etc. functions and dispatched from `updateLights()`'s existing if/else chain (one more `else if` branch):
  - `SOLID`: all listed colors on, others off, no timing.
  - `BLINK`: all listed colors on/off together on `intervalMs` period (same boolean-phase approach as `animateGreenBlink`).
  - `CYCLE`: steps through the ordered color list one at a time, `intervalMs` per step (same style as `animateThinking`'s frame counter, generalized to N colors instead of a fixed 3).
  - `BREATHE`: all listed colors ramp together via the existing `breathValue(nowMs, intervalMs)` helper (reused as-is).
- All existing named commands (`THINKING`, `WORKING`, `BUSY`, `SUCCESS`, `ERROR`, `ALARM`, `GREEN_BLINK`, raw `R`/`Y`/`G`/`A`, OTA commands) are left completely unmodified, so `test_ble.py` and any existing manual workflow keep working.

## Data flow

1. A hook event fires → `AppModel.state.apply(event)` → `state` setter runs → existing `didSet` fires.
2. `didSet` resolves the new `SignalLightBucket` via `SignalLightBucketResolver`.
3. If the bucket differs from the last one sent, look up the configured `SignalLightEffect` for that bucket and hand it to `SignalLightCoordinator.send(_:)`.
4. Coordinator encodes the effect and writes it to the BLE command characteristic if currently connected; otherwise the send is a silent no-op (no queueing — the next state change, or the next successful reconnect, will resync).
5. On (re)connection, the coordinator immediately re-sends the effect for whatever bucket `AppModel` currently reports, so the physical light can never be left showing a stale pre-disconnect state.

## Persistence (UserDefaults, all under an `signalLight.*` key prefix)

- `signalLight.pairedPeripheralID` — `String` (CBPeripheral UUID string), used for auto-reconnect on launch and after unexpected disconnects.
- `signalLight.effects` — JSON-encoded `[SignalLightBucket: SignalLightEffect]`, lazily seeded with the defaults listed above the first time it's read and no value exists yet.

## Error handling

- Bluetooth permission denied (`CBManagerState.unauthorized`) → Settings shows a banner explaining why, with a button that opens System Settings → Privacy & Security → Bluetooth.
- Bluetooth powered off → Settings shows a "Turn on Bluetooth" message; scanning is disabled until it's back on.
- Scan completes with no devices found → empty-state message + "Scan again" button (same tone as the existing `emptyStateBanner` pattern in `SetupSettingsPane`).
- Peripheral disconnects unexpectedly → coordinator status flips to `.disconnected`, auto-reconnect kicks in silently in the background; UI shows the disconnected state without requiring user action.
- Malformed `EFFECT` command reaching the firmware → ignored, board keeps its last valid mode (no crash, no reset).
- No retry queue for BLE writes — a dropped write is superseded by the next real state change or the next reconnect resync. This matches the project's existing "hooks fail open" philosophy: the light is a best-effort indicator, never a blocking dependency.

## Testing plan

- `swift test` (OpenIslandCore target):
  - `SignalLightBucketResolverTests`: covers every combination of session phases relevant to the priority ordering (e.g. one running + one waitingForApproval → `.needsApproval`; all completed → `.idle`; empty session list → `.idle`).
  - `SignalLightCommandEncoderTests`: encode/decode round-trip for all 4 effect types with 1–3 colors and representative intervals; decode rejects malformed strings.
- Manual, via `zsh scripts/launch-dev-app.sh` (per project convention — never plain `swift run` for anything touching persisted state/UI that needs to be inspected visually):
  - Pair with the real ESP32-C3 board from the new Settings tab; confirm scan → connect → status updates.
  - Drive real or demo sessions through waitingForApproval → waitingForAnswer → running → completed and confirm the physical light follows each transition using the configured effects.
  - Change the effect assigned to a bucket (e.g. switch `running` from blink to breathe) and use "Test" to confirm it takes effect immediately.
  - Power-cycle the board mid-session to confirm auto-reconnect and post-reconnect resync to current state.
- Firmware: after editing `led.ino`, flash via USB and manually exercise the new `EFFECT:...` command with a one-off BLE write (e.g. via `test_ble.py`'s existing free-text command prompt) before wiring up the app side, to isolate firmware bugs from app bugs.

## Packaging note

`scripts/package-app.sh` generates the app's `Info.plist` inline; it needs a new `NSBluetoothAlwaysUsageDescription` entry added next to the existing `NSAppleEventsUsageDescription` key, or CoreBluetooth scanning will silently fail to prompt for permission in packaged builds.
