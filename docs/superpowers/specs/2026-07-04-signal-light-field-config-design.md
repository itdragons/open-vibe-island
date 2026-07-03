# Signal Light Field Configuration — Design Spec

Status: Approved for planning
Date: 2026-07-04

## Summary

The signal light firmware (`signal-light/led_esp32c3/`) is flashed identically onto every mass-produced unit, with pin assignments and the BLE device name hard-coded in `config.h`. Two real-world defects surfaced once units started shipping:

1. **Miswired LEDs** — during soldering, a color's wire sometimes lands on the wrong GPIO (e.g. red ends up on GPIO 10 instead of the firmware's hard-coded GPIO 5), so the firmware drives the wrong pin (or a pin with nothing useful attached) for that color.
2. **Identical BLE names** — every unit advertises the same name (`drg5`), so once more than one is nearby, Settings' device list can't tell them apart.

This spec adds three related, end-user-facing capabilities to the existing Signal Light Settings pane, all landing on top of the BLE integration from `2026-07-03-signal-light-design.md`:

- **Wiring calibration**: a guided wizard that lets the user visually identify which physical GPIO actually drives each color and remap it — entirely over BLE, no re-soldering.
- **Custom BLE naming**: every unit gets a factory-unique name out of the box, with an optional user-chosen nickname.
- **Global brightness**: a single continuous slider that dims the light regardless of which effect/mode is currently showing.

## Goals

1. A user who receives a unit with a solder mistake can fix it themselves, permanently, from the app — no reflashing, no disassembly.
2. Every unit is distinguishable in the BLE scan list without any setup, and nameable to something meaningful.
3. The light's overall brightness is user-adjustable, continuously, independent of effect/color/speed settings.
4. All of the above works from the **same firmware binary** flashed onto every unit — no per-unit firmware customization.

## Non-goals

- Factory/production-line tooling (a technician-only flow) — this is designed as an ongoing, end-user-facing Settings feature (confirmed with product owner).
- Fixing genuinely broken hardware (open circuit, dead LED, input-only pin) — the wizard must detect and surface this case, but cannot fix it in software.
- Per-bucket (per-state) brightness — brightness is a single global value shared by all four state buckets, not configured per-bucket like effect/colors/interval are.
- Changing the number of logical colors — still exactly three (red/yellow/green); only *which GPIO* backs each one is reassignable.

## Architecture

### Firmware (`signal-light/led_esp32c3/config.h`, `led_esp32c3.ino`)

`config.h`'s existing constants (`led_red`/`led_yellow`/`led_green`, `BLE_DEVICE_NAME`) become **factory defaults only** — identical across every flashed unit. Actual runtime values are read from ESP32 NVS (via the `Preferences` library) and fall back to these defaults when nothing has been persisted yet, so already-deployed units keep working unmodified.

**On boot:**
- Load `pin.red` / `pin.yellow` / `pin.green` from NVS if present; otherwise use the `config.h` defaults.
- Load `ble.name` from NVS if present; otherwise generate `"WG-" + <last 4 hex chars of ESP.getEfuseMac()>`, persist it immediately (so it's stable across reboots), and use it as the advertised name.
- Load `brightness` is **not** persisted in NVS (see Brightness section) — it always starts at a firmware default (100%) until the app resyncs it post-connect, matching how per-bucket effects already work (no firmware-side storage, app-driven resync on every reconnect).

**New commands**, added to the existing single-characteristic text-command protocol (same style as `EFFECT:`/`OTA_*`):

| Command | Behavior |
|---|---|
| `PINTEST:<pin>:<0\|1>` | Drives a raw GPIO high/low directly, bypassing the logical color mapping. Used only by the calibration wizard. Auto-reverts (turns the pin off and restores whatever mode was active before the wizard started) if no further `PINTEST` arrives within 5 seconds — a safety net against the wizard being abandoned mid-flow (app crash, BLE drop). |
| `SETPIN:<R\|Y\|G>:<pin>` | Reassigns a logical color to a physical pin: calls `pinMode(pin, OUTPUT)`, updates the in-memory pin variable, persists to NVS. Applies immediately, no restart needed. |
| `SETNAME:<name>` | Persists a custom BLE name to NVS, acknowledges, then restarts after a short delay (same pattern as the existing `OTA_END` restart) so the new name takes effect on the next advertisement. |
| `GETCONFIG` | Replies via the existing OTA status characteristic (already READ+NOTIFY) with a line like `CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2`. Lets the app show current config without requiring the user to re-run the wizard (e.g. after re-pairing on a different Mac). No new characteristic needed. |
| `BRIGHTNESS:<0-100>` | Sets a global brightness percent applied to whatever the currently-active effect renders. Not persisted (see below). |

**Safety bounds**: `PINTEST` / `SETPIN` reject any pin outside a safe allow-list (ESP32-C3 Super Mini usable GPIOs — expected to be `0–10, 20, 21`, excluding the native-USB pins `18/19`; **the exact list must be verified against the board's actual pinout during implementation**, since strapping-pin behavior and any board-specific reservations aren't confirmed yet). Rejected pins get an error reply over the status characteristic and no state change.

**Rendering changes**: `animateCustomEffect` (the renderer used by all `EFFECT:` commands — i.e. everything the app actually drives) computes a brightness-scaled "on" value instead of the hard-coded `LED_ON`:
- `onValue = map(brightnessPercent, 0, 100, LED_OFF, LED_ON)` (inverted PWM: `LED_OFF=255`, `LED_ON=0`).
- SOLID / BLINK / CYCLE substitute `onValue` wherever they currently use `LED_ON`.
- BREATHE rescales its existing `breathValue()` curve so its peak lands on `onValue` instead of `LED_ON`, keeping the trough at `LED_OFF` (off).
- Manual single-letter commands (`R`/`Y`/`G` + explicit 0–255 value) are **not** affected — those already give the caller exact PWM control and are a separate code path from the bucket-driven effects.

A new `MODE_PIN_TEST` firmware mode isolates calibration state from `currentMode`, so a `PINTEST` sequence can't be silently overwritten by (or silently overwrite) a live `EFFECT:` push from an in-flight session-state change.

### App (`SignalLightCoordinator.swift`, `SignalLightSettingsPane.swift`, `AppModel.swift`)

**`SignalLightCoordinator` additions:**
- `sendRaw(_ command: String)` — generic text command send, alongside the existing `send(_ effect:)`.
- Subscribes to NOTIFY on the OTA status characteristic (not currently used app-side) to receive `GETCONFIG` replies and `PINTEST` acks/errors.
- `isCalibrating: Bool` — while `true`, suppresses the automatic `EFFECT:` push that `AppModel` fires on every session-bucket change (AppModel.swift:54–57), so a live session transition can't interrupt a `PINTEST` sequence. Cleared (and a resync effect re-sent) when the wizard finishes or is cancelled.
- `currentBrightnessProvider: (() -> Int?)?` — mirrors the existing `currentEffectProvider`; called on (re)connect to resend the last-known brightness, exactly like effects are resynced today.

**Wiring calibration wizard** (new sheet/modal in `SignalLightSettingsPane`, device-connected only):
1. Steps through a safe candidate GPIO list, lighting one at a time (`PINTEST:<pin>:1`, ~1.5s) and asking "which color did you just see? (Red / Yellow / Green / Nothing)".
2. Records the mapping as answers come in; auto-completes once all three colors are identified. A "redo" action is always available.
3. If a candidate pin produces no response after being flagged "Nothing" through the full list, the wizard reports that color couldn't be located and suggests a hardware check, rather than silently leaving it unmapped.
4. On completion, sends the three `SETPIN` commands, then plays a quick confirmation (`EFFECT:CYCLE:RYG:200` for ~1s) so the user visually confirms the fix landed correctly.

**Rename device**: text field + button in the existing device section, showing the current name (already surfaced via `SignalLightDiscoveredDevice`/connected status). Sends `SETNAME`, shows a "device is restarting and will reconnect automatically" message. No special handling needed for the reconnect — `CBPeripheral.identifier` is derived from the Bluetooth hardware address, not the advertised name, so the existing `pairedPeripheralID`-based auto-reconnect (`attemptAutoReconnect()`) picks the same device back up once it re-advertises under the new name.

**Brightness slider**: new section between the device and modes sections — a single continuous `Slider(0...100)`. Dragging sends `BRIGHTNESS:` live (lightly throttled to avoid saturating the BLE link during a fast drag); no separate "Test" button needed since dragging while connected already gives real-time visual feedback on whatever the light is currently showing.

`AppModel` additions:
- `signalLightBrightness: Int` (0–100, UserDefaults-backed, default 100), sends `BRIGHTNESS:` on every change.

## Data flow

**Calibration**: user opens wizard → coordinator sets `isCalibrating = true` → wizard drives `PINTEST` per candidate pin, collecting user answers → on completion, coordinator sends `SETPIN` × 3 → firmware persists to NVS and applies immediately → coordinator clears `isCalibrating`, resyncs the current bucket's effect (in case a session transitioned while the wizard was open).

**Rename**: user submits new name → `SETNAME` sent → firmware persists, acks, restarts → peripheral disconnects → `didDisconnectPeripheral` → `attemptAutoReconnect()` (existing code, unchanged) → reconnect succeeds under the new advertised name → Settings UI reflects it via the peripheral's live `.name`.

**Brightness**: slider drag → `AppModel.signalLightBrightness` didSet → `BRIGHTNESS:` sent immediately (throttled) → firmware recomputes `onValue` and applies to whatever's currently rendering. On reconnect, `currentBrightnessProvider` resends the last value so a power-cycled unit doesn't reset to 100%.

**Config readback**: on demand (e.g. Settings pane appears while connected, or a "refresh" affordance), coordinator sends `GETCONFIG`, parses the `CONFIG:` NOTIFY reply, and updates displayed pin mapping / name — useful after re-pairing on a different Mac where the app has no local memory of what was previously configured.

## Persistence

| Value | Where | Why |
|---|---|---|
| Pin mapping (`pin.red/yellow/green`) | Firmware NVS | Permanent per-unit hardware fact; must survive power cycles and re-pairing on any Mac. |
| BLE name (`ble.name`) | Firmware NVS | Same — device identity, not an app preference. |
| Brightness | App only (UserDefaults), resynced to firmware on every (re)connect | A user preference like the per-bucket effects already are; not persisting it in NVS avoids extra flash wear from frequent slider drags. |
| Per-bucket effects | App only (existing, unchanged) | Same rationale as brightness. |

## Error handling

- `SETPIN`/`PINTEST` with an out-of-range pin → firmware replies with an error over the status characteristic; app surfaces it as "unsupported pin" and skips it in the wizard's candidate list going forward.
- Wizard abandoned mid-flow (app closed, BLE drop) → firmware's 5-second `PINTEST` timeout auto-reverts to the prior mode; no lingering lit LED.
- A color never identified during calibration → wizard reports it explicitly and leaves that color's existing mapping untouched (doesn't guess).
- `SETNAME` fails to restart / reconnect within a timeout → Settings shows the existing `.disconnected` state; user can manually reconnect from the device list like any other disconnect (no new error path needed — reuses existing disconnect handling).
- `GETCONFIG` on firmware that predates this feature (older flashed units, pre-upgrade) → no `CONFIG:` reply arrives; app treats this as "unknown config," and the calibration wizard still works going forward as a write-only operation.

## Testing plan

- `swift test` (OpenIslandCore/App targets): calibration wizard state machine (answer sequencing, redo, "not found" path) as a pure reducer if extracted; brightness/effect resync-on-reconnect logic.
- Firmware: after editing `led_esp32c3.ino`, manually exercise `PINTEST`/`SETPIN`/`SETNAME`/`GETCONFIG`/`BRIGHTNESS` via `signal-light/test_ble.py`'s free-text command prompt before wiring up the app side, to isolate firmware bugs from app bugs.
- Manual, via `zsh scripts/launch-dev-app.sh`:
  - Deliberately wire a spare LED to an "unexpected" pin, run the wizard, confirm it identifies and corrects the mapping, and that the fix survives a power cycle.
  - Rename a connected device, confirm it reconnects automatically post-restart and the new name is reflected in Settings.
  - Drag the brightness slider while a bucket effect is actively showing (e.g. `running` blink) and confirm live dimming; power-cycle the board and confirm brightness resyncs on reconnect rather than resetting to 100%.
  - Run `GETCONFIG` after reinstalling the app (simulating a fresh pair with no local memory) and confirm the previously-set pin mapping and name are read back correctly.
