# Signal Light: Tri-Color Breathe While Bluetooth Disconnected

## Problem

The signal light firmware (`signal-light/led_esp32c3/led_esp32c3.ino`) has no
notion of "not connected." Out of the box, `redValue`/`yellowValue`/`greenValue`
default to `LED_ON`, so a fresh device just sits fully lit until the Mac app
connects and sends a mode command. After that, if the BLE link drops (app
quit, Bluetooth toggled off, out of range), the device silently freezes on
whatever mode/brightness it was last told to show — there's no way to tell,
just by looking at the hardware, whether it's connected and idle vs. stuck
disconnected.

We want the physical light to visibly indicate "not connected" on its own,
since it has no other channel to communicate that once disconnected. The
signal is: all three LEDs (red, yellow, green) breathing in sync — fade in,
fade out, together — for as long as no BLE central is connected. This is a
firmware-only behavior; the Mac app's Settings preview is unaffected.

## Scope

- Firmware only: `signal-light/led_esp32c3/led_esp32c3.ino`, `config.h`.
- No BLE protocol changes. No new commands. No app-side changes — the Mac
  app's Settings preview (`SignalLightSettingsPane`) and its bucket-effect
  model are left exactly as they are today. The firmware handles the
  disconnected state entirely on its own, and the app's existing
  connect-time resync already restores the correct bucket effect once
  reconnected.

## Firmware behavior

Add a `MODE_DISCONNECTED` case to `LedMode` and a `bleConnected` flag, tracked
via the BLE server callbacks:

- `ServerCallback::onConnect` sets `bleConnected = true`.
- `ServerCallback::onDisconnect` (existing — currently just restarts
  advertising) additionally sets `bleConnected = false` and calls
  `startMode(MODE_DISCONNECTED)`.
- In `setup()`, once advertising starts, call `startMode(MODE_DISCONNECTED)`
  so a freshly-booted, never-yet-paired device breathes immediately instead
  of sitting solid-on.

`startMode()` already sets `lightOn = true` as part of switching modes, so
entering `MODE_DISCONNECTED` **unconditionally overrides** the light-off
switch and whatever mode was active before disconnecting. This is
intentional: while disconnected, the app has no channel to enforce an "off"
preference on the hardware anyway, so showing the connect-me signal
regardless of prior state is more useful than freezing on stale output. On
reconnect, the app's existing resync flow re-applies the user's actual
on/off + bucket-effect state, so this doesn't fight with user intent for more
than an instant.

Rendering: three-LED synchronized breathing is already exactly what
`animateWorking()` does (`setLights(value, value, value)` using a shared
`breathValue()`). Rather than duplicate that logic, `updateLights()` dispatches
`MODE_DISCONNECTED` to the same `animateWorking()` function:

```cpp
} else if (currentMode == MODE_WORKING || currentMode == MODE_DISCONNECTED) {
  animateWorking(nowMs);
}
```

`MODE_WORKING` and `MODE_DISCONNECTED` can never be active at the same time
(one only occurs while connected and the app is actively driving it; the
other only while disconnected), so sharing the exact same visual is safe —
there's no runtime ambiguity for the user.

Bump `const String FIRMWARE_VERSION` in `config.h` from `"1.0.0"` to
`"1.1.0"` (new user-visible behavior). Compiling and flashing/OTA-pushing the
new binary is a manual step outside this repo's build tooling — not part of
this change.

## Out of scope

- OTA flow, PINTEST calibration wizard, SETPIN/SETNAME — untouched.
- `signal-light/firmware/version.json` / `signal-light.bin` (OTA distribution
  test fixtures) — unrelated to this change, not updated here.
- Any change to how brightness percent applies to named modes — `WORKING`
  and now `MODE_DISCONNECTED` intentionally ignore `brightnessPercent`,
  consistent with the other named animation modes (`BUSY`, `ERROR`,
  `ALARM`, etc.), which already only the `EFFECT:` custom-effect path
  respects.
- Mac app: `SignalLightSettingsPane` live preview, `SignalLightPreviewPill`,
  and localization strings — no changes. The preview keeps showing the
  bucket effect / off state exactly as it does today; it does not attempt to
  mirror the firmware's disconnected-breathing behavior.

## Testing

- Firmware: manual, on real hardware — flash, observe boot breathing before
  first pairing; connect via app and confirm it switches to the correct
  bucket effect; disconnect (quit app / toggle Bluetooth off) and confirm
  breathing resumes, overriding whatever mode/off-state was active.
- App: no changes, so no app-side testing needed for this spec.
