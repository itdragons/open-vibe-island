# Signal Light Active-High Polarity Support — Design Spec

Status: Approved for planning
Date: 2026-07-17

## Summary

The signal-light firmware (`signal-light/esp32c3/esp32c3-1.2.2/`) hard-codes active-low LED wiring everywhere: `configureLedChannel` always sets the LEDC channel's `output_invert` flag to `1`, the boot-time "force LEDs off before LEDC takes over" step always drives `HIGH`, and the `PINTEST` wiring-calibration helper (`driveTestPin`) always drives `LOW` to light a candidate pin. Boards wired active-high (LED lights when the GPIO goes high, not low) are completely unsupported today — every mode would render inverted or not at all.

This spec adds a runtime, persisted, globally-scoped polarity setting to the firmware, and end-to-end app support for reading and changing it: a toggle in Signal Light Settings, plus an escape hatch inside the existing wiring-calibration wizard for the case where a wrong polarity assumption makes every candidate pin look dead during calibration.

## Goals

1. A user whose signal-light hardware is wired active-high can select that in the app and have every existing mode/effect/brightness/manual-control code path render correctly, with no firmware reflash.
2. Already-deployed active-low units keep working with zero config changes — polarity defaults to today's behavior.
3. Switching polarity takes effect immediately; no restart.
4. The wiring-calibration wizard remains usable even when the device's current polarity setting doesn't match the actual hardware — the user can flip polarity from inside the wizard instead of getting stuck on "nothing lights up."

## Non-goals

- Per-LED (per-color) polarity. All three LEDs on a unit share one physical driving convention; this is a single global flag, not a `SETPIN`-style per-color setting.
- Auto-detecting polarity without user input. The wizard's escape hatch is a manual retry action, not automatic sensing.
- Any change to brightness math, effect encoding, or the four session-state buckets — those are untouched; the fix is isolated to the electrical-level layer underneath them.

## Architecture

### Firmware (`signal-light/esp32c3/esp32c3-1.2.2/esp32c3-1.2.2.ino`, `config.h`)

New runtime state: `bool ledActiveHigh`, backed by NVS key `ledActiveHigh`, **default `false`** — matches every unit shipped to date, so no migration is needed.

**New command**, added to the existing single-characteristic text-command protocol (same style as `SETPIN:`/`BRIGHTNESS:`):

| Command | Behavior |
|---|---|
| `SETPOLARITY:LOW\|HIGH` | Sets `ledActiveHigh`, persists to NVS, and immediately reconfigures all three LEDC channels' `output_invert` flag (`configureAllLedChannels()`) — no restart, same live-reconfigure mechanism `SETPIN` already uses when rebinding a channel to a new GPIO. Rejects anything other than `LOW`/`HIGH` with an error reply over the status characteristic, same pattern as `SETPIN`'s pin validation. |

**Why this is a small, contained change:** `writeLedChannel`'s `duty = PWM_MAX - value` formula already produces the correct "0 = brightest, 255 = off" semantics for *either* value of `output_invert` — the invert flag only decides which electrical direction that duty cycle maps to. So flipping `configureLedChannel`'s hard-coded `channelConfig.flags.output_invert = 1` to `ledActiveHigh ? 0 : 1` is enough to make every existing rendering path (breathe, blink, cycle, solid, manual single-letter commands) work unchanged under both polarities. No other animation/brightness code needs to know polarity exists.

Two other spots currently hard-code the active-low assumption outside the LEDC/`output_invert` mechanism and must be fixed to read `ledActiveHigh`:
- The boot-time sequence that forces all three GPIOs to a safe "off" level before `configureAllLedChannels()` takes over (currently always `digitalWrite(pin, HIGH)`) — must use `ledActiveHigh ? LOW : HIGH`. `ledActiveHigh` is read from NVS at the same point pin assignments and the BLE name already are, before this sequence runs.
- `driveTestPin`, used by `PINTEST` — currently always `digitalWrite(pin, on ? LOW : HIGH)`. Must use the same polarity-aware on/off level. Left unfixed, the calibration wizard would look completely broken (no candidate pin ever appears to light) on active-high hardware.

No change is needed to the deep-sleep hold logic (`holdLedOutputsOffDuringSleep`) — it just latches whatever electrical level `turnOffLights()` already drove through the (now polarity-correct) LEDC channels, which is a static level regardless of which polarity is active.

**`GETCONFIG` reply** gains a field: `CONFIG:R=6,Y=7,G=10,NAME=WG-A1B2,POL=LOW`.

`FIRMWARE_VERSION` in `config.h` is bumped as part of implementation, per the existing per-build convention.

### App protocol layer (`Sources/OpenIslandCore/SignalLight.swift`)

- `SignalLightControlCommand.setPolarity(activeHigh: Bool) -> String` → `"SETPOLARITY:HIGH"` / `"SETPOLARITY:LOW"`.
- `SignalLightDeviceConfig` gains `activeHigh: Bool`.
- `SignalLightConfigDecoder.decode` parses the new `POL` field, **defaulting to `false` when absent** (rather than failing to decode) so replies from devices still running firmware that predates this feature keep parsing successfully.

### App connection layer (`Sources/OpenIslandApp/SignalLightCoordinator.swift`)

On every (re)connect, alongside the existing effect/brightness resync in `didDiscoverCharacteristicsFor`, send `GETCONFIG` once to populate `lastDeviceConfig`. This activates plumbing (`lastDeviceConfig`, the `CONFIG:` decode path on the OTA-status NOTIFY channel) that already exists but is currently never triggered by anything.

Polarity is treated as a **hardware fact about the physical device**, like the pin mapping — not a user preference like brightness/effect. The app reads it from the device (`GETCONFIG`) and only ever *pushes* a change when the user explicitly acts (Settings toggle or wizard escape hatch); it does **not** blindly resync a locally-remembered value on every connect the way brightness does. Resyncing blindly would risk silently reverting a previously-correct on-device polarity setting if the app's local state ever fell out of sync (reinstall, different Mac, re-pairing).

### Settings UI (`Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`)

- New row: a segmented control ("低电平点亮" / "高电平点亮") bound to `lastDeviceConfig?.activeHigh`, sending `SETPOLARITY` on change. Disabled while disconnected, mid-OTA (`isTransferring`), or mid-calibration (`isCalibrating`) — same disable rules already used by neighboring hardware controls.
- Wizard escape hatch, inside `calibrationWizardView`: a secondary button always visible alongside the existing 红/黄/绿/都没亮 observation buttons — "灯一直不亮？试试另一种电平极性". Tapping it flips the assumed polarity, sends `SETPOLARITY`, and re-fires `PINTEST:<currentPin>:1` for the *current* candidate pin — without calling `recordCalibrationObservation` or otherwise touching the wizard's `currentIndex`/`mapping`. If the flip was correct, the user simply continues answering from that same pin. (Once any single color has been successfully identified during a run, polarity is implicitly confirmed correct; the button remains visible for the rest of the wizard regardless, which is harmless — pressing it again just flips back.)

### Localization

New keys across `en.lproj` / `zh-Hans.lproj` / `zh-Hant.lproj` for the toggle label/options and the escape-hatch button text, following the existing `settings.signalLight.*` naming convention.

## Data flow

**Read on connect**: peripheral connects → characteristics discovered → coordinator sends `GETCONFIG` (alongside existing effect/brightness resync) → firmware replies `CONFIG:...,POL=LOW` over the OTA-status NOTIFY characteristic → `SignalLightConfigDecoder` parses it → `lastDeviceConfig` updates → Settings pane's polarity control reflects the true on-device value.

**User toggles polarity in Settings**: `SETPOLARITY:HIGH` sent → firmware persists to NVS, reconfigures all three LEDC channels' `output_invert` live → next render frame (within one `loop()` iteration) shows correctly under the new polarity. A brief all-off flicker during the reconfigure is expected and acceptable, same as any other mode-start transition.

**Wizard escape hatch**: user taps "试试另一种电平极性" mid-wizard → coordinator sends `SETPOLARITY` with the flipped value → coordinator re-sends `PINTEST:<currentPin>:1` for the same pin the wizard is currently asking about → user observes whether it now lights → wizard proceeds exactly as if this were the first attempt at that pin.

## Persistence

| Value | Where | Why |
|---|---|---|
| `ledActiveHigh` | Firmware NVS | Hardware fact about the physical device, must survive power cycles and re-pairing on any Mac — same rationale as pin mapping and BLE name. |
| App-side polarity display | Not persisted locally; read via `GETCONFIG` on each connect | Avoids the app's local state ever diverging from the device's actual NVS value. |

## Error handling

- `SETPOLARITY` with anything other than `LOW`/`HIGH` → firmware replies with an error over the status characteristic, same pattern as `SETPIN`'s out-of-range-pin rejection; no state change.
- `GETCONFIG` reply missing the `POL` field (firmware predates this feature) → decoder defaults `activeHigh` to `false`; Settings shows "低电平点亮" until/unless the user upgrades firmware and explicitly changes it.
- Wrong polarity assumed at the start of a calibration run → every candidate pin appears not to light; the always-visible escape-hatch button lets the user recover without restarting the wizard or losing already-recorded mapping progress.
- Toggling polarity while disconnected → control is disabled, consistent with other hardware controls that require an active connection.

## Testing plan

- `swift test` (`Tests/OpenIslandCoreTests/SignalLightTests.swift`): extend `SignalLightControlCommandTests` with `setPolarity(activeHigh:)` encoding for both values; extend `SignalLightConfigDecoderTests` with a `POL=HIGH`/`POL=LOW` round-trip and a case confirming a `CONFIG:` line lacking `POL` still decodes with `activeHigh == false`.
- Firmware: after editing the `.ino`, manually exercise `SETPOLARITY:LOW`/`SETPOLARITY:HIGH`/`GETCONFIG` via `signal-light/test_ble.py`'s free-text command prompt before wiring up the app side, to isolate firmware bugs from app bugs.
- Manual, via `zsh scripts/launch-dev-app.sh`, against real hardware in both wiring configurations:
  - Confirm every mode (breathe/blink/cycle/solid/manual) renders correctly with polarity set to match the actual wiring, and incorrectly (as expected) when deliberately mismatched.
  - Toggle polarity live from Settings while a mode is actively rendering; confirm it takes effect immediately with no restart and no more than a brief flicker.
  - Run the wiring-calibration wizard starting with the wrong polarity assumed; confirm every candidate pin looks dead, use the escape hatch, and confirm the wizard continues correctly from the same pin without losing prior progress.
  - Power-cycle the device after setting polarity and confirm it persists (reads back correctly via `GETCONFIG` on reconnect).
  - Reinstall the app (simulating no local memory) and confirm `GETCONFIG` on connect correctly reflects a previously-set active-high device rather than defaulting the UI to "低电平点亮".
