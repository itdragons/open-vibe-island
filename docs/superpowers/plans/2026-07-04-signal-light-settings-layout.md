# Signal Light Settings Layout Reorganization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regroup the Signal Light settings pane's 4 sections into 3, organized by how often a control is touched — connection, light behavior (switch → brightness → per-state effects), and a collapsed-by-default "device management" group for rename/wiring-calibration/firmware — instead of by which feature landed the control.

**Architecture:** Pure view-layer reorganization of one file, `SignalLightSettingsPane.swift`. No change to `AppModel`, `SignalLightCoordinator`, the firmware protocol, or `SignalLightCalibrationWizard` — every method call this pane makes is relocated verbatim, never rewritten. One new piece of state (`isDeviceManagementExpanded`) drives a `DisclosureGroup`.

**Tech Stack:** Swift 6.2, SwiftUI.

## Global Constraints

- Do not use TDD for this work — apply the changes directly, no failing-test-first steps. (Explicit user instruction; also consistent with this codebase's existing convention that SwiftUI-facing code in `OpenIslandApp` has no automated tests and is verified manually/visually instead.)
- This is a pure re-layout: every existing gating condition (`.unauthorized`/`.poweredOff`/`.connected`/default; `isTransferring` disabling buttons; the empty-name rename guard) and every method call must be preserved exactly — only *which section* a control renders inside changes.
- No new navigation surface — everything stays inside the existing `SignalLightSettingsPane` / "Signal Light" Settings tab.
- Follow the existing localization pattern: `lang.t("settings.signalLight.<key>")`, with matching entries added to all three `Localizable.strings` files.
- Design spec: `docs/superpowers/specs/2026-07-04-signal-light-settings-layout-design.md`. Refer to it for full rationale — this plan implements it as-is.

---

### Task 1: Localization — new section-header keys

**Files:**
- Modify: `Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/OpenIslandApp/Resources/zh-Hant.lproj/Localizable.strings`

**Interfaces:**
- Produces: `settings.signalLight.lightSection` and `settings.signalLight.deviceManagement` keys, consumed by Task 2.

- [ ] **Step 1: Append to `en.lproj/Localizable.strings`**

After the existing `"settings.signalLight.calibrateDone" = "Done";` line, add:

```
"settings.signalLight.lightSection" = "Light";
"settings.signalLight.deviceManagement" = "Device Management";
```

- [ ] **Step 2: Append to `zh-Hans.lproj/Localizable.strings`**

After the existing `"settings.signalLight.calibrateDone" = "完成";` line, add:

```
"settings.signalLight.lightSection" = "灯光";
"settings.signalLight.deviceManagement" = "设备管理";
```

- [ ] **Step 3: Append to `zh-Hant.lproj/Localizable.strings`**

After the existing `"settings.signalLight.calibrateDone" = "完成";` line, add:

```
"settings.signalLight.lightSection" = "燈光";
"settings.signalLight.deviceManagement" = "裝置管理";
```

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenIslandApp/Resources/*/Localizable.strings
git commit -m "feat: localize signal light settings' new light/device-management section headers"
```

---

### Task 2: Regroup `SignalLightSettingsPane` into 3 sections

**Files:**
- Modify: `Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`

**Interfaces:**
- Consumes: `settings.signalLight.lightSection` / `.deviceManagement` from Task 1.
- Produces: nothing consumed by later tasks — this is the final task in this plan.

- [ ] **Step 1: Add the new `@State` for the disclosure group**

Replace:

```swift
    @State private var selectedFirmwareURL: URL?
    @State private var isShowingFlashConfirmation = false
    @State private var renameText = ""
    @State private var isShowingRenameReconnectNotice = false
    @State private var wizard: SignalLightCalibrationWizard?
```

with:

```swift
    @State private var selectedFirmwareURL: URL?
    @State private var isShowingFlashConfirmation = false
    @State private var renameText = ""
    @State private var isShowingRenameReconnectNotice = false
    @State private var wizard: SignalLightCalibrationWizard?
    @State private var isDeviceManagementExpanded = false
```

- [ ] **Step 2: Update `body`'s `Form` to the new 3-section list**

Replace:

```swift
    var body: some View {
        Form {
            deviceSection
            brightnessSection
            modesSection
            firmwareSection
        }
        .formStyle(.grouped)
```

with:

```swift
    var body: some View {
        Form {
            deviceSection
            lightSection
            deviceManagementSection
        }
        .formStyle(.grouped)
```

- [ ] **Step 3: Trim `deviceSection` down to connection-management only**

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
                Button(lang.t("settings.signalLight.calibrateWiring")) {
                    beginCalibration()
                }
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

(The light switch, rename row, and calibrate-wiring button removed here are not deleted — they reappear in `lightSection` and `deviceManagementSection` in later steps.)

- [ ] **Step 4: Replace `brightnessSection` with the merged `lightSection`**

Replace:

```swift
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

with:

```swift
    @ViewBuilder
    private var lightSection: some View {
        Section(lang.t("settings.signalLight.lightSection")) {
            Toggle(lang.t("settings.signalLight.lightSwitch"), isOn: $model.signalLightEnabled)

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

            Button(lang.t("settings.signalLight.resetDefaults")) {
                model.signalLightEffects = Dictionary(
                    uniqueKeysWithValues: SignalLightBucket.allCases.map { ($0, .defaultEffect(for: $0)) }
                )
            }
        }
    }
```

- [ ] **Step 5: Delete the now-standalone `modesSection`**

The `ForEach`/reset-button content that used to live in `modesSection` was just moved into `lightSection` in Step 4 — `modesSection` itself is now a leftover duplicate. Replace:

```swift
    // MARK: Modes

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

            Button(lang.t("settings.signalLight.resetDefaults")) {
                model.signalLightEffects = Dictionary(
                    uniqueKeysWithValues: SignalLightBucket.allCases.map { ($0, .defaultEffect(for: $0)) }
                )
            }
        } header: {
            Text(lang.t("settings.signalLight.modes"))
        }
    }

    private func bucketTitle(_ bucket: SignalLightBucket) -> String {
```

with:

```swift
    private func bucketTitle(_ bucket: SignalLightBucket) -> String {
```

- [ ] **Step 6: Replace `firmwareSection` with `deviceManagementSection`**

Replace:

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
```

with:

```swift
    // MARK: Device Management

    @ViewBuilder
    private var deviceManagementSection: some View {
        Section {
            DisclosureGroup(lang.t("settings.signalLight.deviceManagement"), isExpanded: $isDeviceManagementExpanded) {
                if case .connected = model.signalLight.status {
                    renameRow
                    Divider()
                    Button(lang.t("settings.signalLight.calibrateWiring")) {
                        beginCalibration()
                    }
                    Divider()
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
    }
```

- [ ] **Step 7: Build**

```bash
swift build
```
Expected: builds with no errors.

- [ ] **Step 8: Manual verification**

```bash
zsh scripts/launch-dev-app.sh
```
In Settings → Signal Light, confirm:
- Exactly 3 sections render, in order: Device, Light (switch + slider + 4 mode rows + reset button), Device Management (collapsed).
- Device Management is collapsed by default; expanding it while disconnected shows the "connect first" hint; expanding it while connected shows rename, then a divider, then the calibrate-wiring button, then a divider, then the firmware version/file-picker/flash controls.
- The light switch and brightness slider in the Light section still work exactly as before (if a physical device is available, confirm it visibly responds).
- Renaming, wiring calibration, and firmware flashing (from inside the now-collapsed group) all still work exactly as before.

- [ ] **Step 9: Commit**

```bash
git add Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift
git commit -m "feat: regroup Signal Light settings into device/light/device-management sections"
```
