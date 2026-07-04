# Signal Light Settings Layout Reorganization — Design Spec

Status: Approved for planning
Date: 2026-07-04

## Summary

`SignalLightSettingsPane` has grown from 2 sections (Device, Modes) at initial launch to 4 (Device, Brightness, Modes, Firmware) as calibration, renaming, and brightness landed. The result has three concrete problems: connection-management controls (scan/connect/disconnect) sit in the same section as unrelated behavior controls (the light switch) and unrelated maintenance actions (rename, calibrate wiring); a standalone one-slider "Brightness" section sits between Device and Modes for no structural reason; and every control — from the everyday light switch to the once-ever wiring calibration — renders unconditionally, making the page long regardless of how often a given control is actually touched.

This spec regroups the pane into 3 top-level sections by how often and why a control is used — connection, light behavior (from the master switch down to per-state effect detail), and device management — and collapses the lowest-frequency group (rename, wiring calibration, firmware OTA) behind a disclosure group that starts closed.

## Goals

1. Group controls by function, not by "which feature landed them" — connection management, light behavior, and device maintenance each get exactly one section.
2. Reduce the page's default visible length by collapsing the three lowest-frequency, most-technical actions (rename, wiring calibration, firmware OTA) behind a single disclosure group that starts closed.
3. Preserve every existing behavior, gating condition, and piece of logic exactly as-is — this is a pure re-layout, not a functional change.

## Non-goals

- No new navigation surface (no new Settings tab, no sub-tabs, no sheet-based "Advanced" page). Everything stays inside the existing `SignalLightSettingsPane` / "Signal Light" Settings tab, confirmed with the product owner.
- No change to `AppModel`, `SignalLightCoordinator`, the firmware protocol, or `SignalLightCalibrationWizard` — every method this pane calls (`model.signalLight.sendRaw(...)`, `model.signalLight.send(...)`, `beginCalibration()`, `presentFirmwarePicker()`, etc.) keeps its exact existing signature and behavior.
- No change to per-bucket mode configuration itself (still 4 buckets, still type/colors/interval/test) — only which section it renders inside.
- Not addressing the Modes section's own internal density (4 rows × picker + 3 toggles + stepper + button each) — that section is inherently the feature's core content and stays as-is; if it ever needs its own internal collapsing, that's a separate future spec.

## Architecture

### Section 1 — Device (`deviceSection`, unchanged in place, trimmed in content)

Keeps: the status row (label + `statusBadge`), and the connection-state switch (`unauthorizedBanner` / "turn on Bluetooth" message / discovered-devices list + scan button / disconnect button).

Removes from this section (relocated below, not deleted): the light-switch `Toggle`, `renameRow`, and the "校准接线" button. This section becomes purely about *which device am I talking to and am I connected to it* — no behavior controls, no maintenance actions.

### Section 2 — Light (`lightSection`, new; replaces the standalone `brightnessSection` and absorbs the light switch and the existing `modesSection` content)

One section, ordered coarse-to-fine:
1. Light-switch `Toggle` (moved from Device) — the master control.
2. Brightness `Slider` + percentage text (moved from the old standalone `brightnessSection`) — the global intensity control.
3. The 4 existing `SignalLightModeRow`s (unchanged internals) — per-state effect detail.
4. The existing "恢复默认" (reset to defaults) button.

Rationale for merging brightness/switch with modes rather than keeping them separate: all four things are "how the light behaves," read top-to-bottom from coarsest control to finest. Splitting them into two sections previously implied brightness/switch were a different category from mode effects, when they're actually the same category at a different level of detail.

Section header: reuse the existing `settings.signalLight.modes` localization key text (already "模式"/"Modes") is too narrow now that the section also holds the switch and brightness — add one new key `settings.signalLight.lightSection` (proposed value: "灯光" / "Light" / "燈光") and use it as this section's header, retiring `modes`' use as a header (the key itself can stay defined and unused, or be deleted — deleting it needs a grep confirmation no other call site references it before removal).

### Section 3 — Device Management (`deviceManagementSection`, new; collapsed by default)

A `Section` whose sole content is a `DisclosureGroup`, bound to new state `@State private var isDeviceManagementExpanded = false` (closed by default — this is the section responsible for shortening the page).

When expanded and connected, in order, separated by `Divider()`:
1. `renameRow` (moved from Device) — unchanged internals.
2. The "校准接线" button (moved from Device) — unchanged action (`beginCalibration()`).
3. The existing firmware block: `firmwareVersionRow`, `firmwareFilePickerRow`, `firmwareActionRow` — unchanged internals, currently `firmwareSection`'s content.

When expanded and *not* connected: a single "请先连接设备" hint (reusing the existing `settings.signalLight.firmwareNeedsConnection` string, now describing the whole group rather than just firmware) — matches the already-approved behavior of showing the group but explaining it needs a connection, rather than hiding it entirely.

Header text: new key `settings.signalLight.deviceManagement` (proposed value: "设备管理" / "Device Management" / "裝置管理").

### `body`'s `Form`

```swift
Form {
    deviceSection
    lightSection
    deviceManagementSection
}
```

(Was: `deviceSection`, `brightnessSection`, `modesSection`, `firmwareSection`.)

## Data flow

None — this is a pure view-layer reorganization. No new state beyond `isDeviceManagementExpanded`; no existing state (`selectedFirmwareURL`, `isShowingFlashConfirmation`, `renameText`, `isShowingRenameReconnectNotice`, `wizard`) changes meaning or ownership. Every method call (`model.signalLight.connect(deviceID:)`, `model.signalLight.disconnect()`, `model.signalLight.sendRaw(...)`, `model.signalLight.send(...)`, `beginCalibration()`, `presentFirmwarePicker()`, `model.signalLight.beginFirmwareUpdate(fileURL:)`, `model.signalLight.cancelFirmwareUpdate()`) is relocated verbatim, not rewritten.

## Localization

Two new keys, added to all three `Localizable.strings` files (`en`, `zh-Hans`, `zh-Hant`):

- `settings.signalLight.lightSection` — new header for the merged switch+brightness+modes section.
- `settings.signalLight.deviceManagement` — new header for the collapsed disclosure group.

`settings.signalLight.modes` stays defined (other call sites, if any, are unaffected); if a grep confirms this pane was its only consumer, it becomes unused and can be removed in the same change — decided at implementation time, not a design-time requirement.

No other existing keys change meaning; all reused verbatim in their new location (`settings.signalLight.device`, `.brightness`, `.rename*`, `.calibrateWiring`, `.firmware*`, etc.).

## Error handling

None new — every gated/conditional branch (`.unauthorized`, `.poweredOff`, `.connected`, disconnected/default; `isTransferring` disabling buttons during a firmware flash; empty-name guard on rename) is preserved exactly, just relocated.

## Testing plan

No automated tests apply to this SwiftUI file, per this codebase's existing convention (confirmed by the original Signal Light integration's plan and the field-configuration plan that followed it — CoreBluetooth/SwiftUI-facing code here has none). Verification is `swift build` succeeding, plus a manual pass via `zsh scripts/launch-dev-app.sh`:

- Confirm the pane renders 3 sections in the new order, with Device Management collapsed by default.
- Toggle the light switch and drag brightness from within the merged Light section — confirm both still work exactly as before (physical light responds, if a real device is available).
- Configure and test a mode row inside the merged Light section — confirm unchanged behavior.
- Expand Device Management while disconnected — confirm the "connect first" hint. Connect, expand again — confirm rename, calibrate-wiring, and firmware controls all render and behave exactly as before (rename triggers reconnect notice; calibrate-wiring opens the existing sheet; firmware file-pick/flash flow unchanged).
- Confirm nothing else in the app (other Settings tabs, `AppModel`, the bridge) is touched.
