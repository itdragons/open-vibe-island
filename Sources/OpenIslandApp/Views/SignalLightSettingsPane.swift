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

    // MARK: Device

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
            default:
                discoveredDevicesList
                Button(lang.t("settings.signalLight.scan")) {
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
                Text(lang.t("settings.signalLight.scanning"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .disconnected:
            Text(lang.t("settings.signalLight.notConnected"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .poweredOff:
            Text(lang.t("settings.signalLight.bluetoothOff"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .unauthorized:
            Text(lang.t("settings.signalLight.permissionNeeded"))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var unauthorizedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lang.t("settings.signalLight.permissionExplanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(lang.t("settings.signalLight.openBluetoothSettings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveredDevicesList: some View {
        if model.signalLight.discoveredDevices.isEmpty {
            Text(model.signalLight.status == .scanning ? lang.t("settings.signalLight.searching") : lang.t("settings.signalLight.noDevicesFound"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.signalLight.discoveredDevices) { device in
                HStack {
                    Text(device.name)
                    Spacer()
                    Button(lang.t("settings.signalLight.connect")) {
                        model.signalLight.connect(deviceID: device.id)
                    }
                }
            }
        }
    }

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
        switch bucket {
        case .needsApproval: lang.t("settings.signalLight.bucket.needsApproval")
        case .needsAnswer: lang.t("settings.signalLight.bucket.needsAnswer")
        case .running: lang.t("settings.signalLight.bucket.running")
        case .idle: lang.t("settings.signalLight.bucket.idle")
        }
    }
}

private struct SignalLightModeRow: View {
    let title: String
    let lang: LanguageManager
    @Binding var effect: SignalLightEffect
    let onTest: (SignalLightEffect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            Picker(lang.t("settings.signalLight.effect"), selection: $effect.type) {
                Text(lang.t("settings.signalLight.solid")).tag(SignalLightEffectType.solid)
                Text(lang.t("settings.signalLight.blink")).tag(SignalLightEffectType.blink)
                Text(lang.t("settings.signalLight.cycle")).tag(SignalLightEffectType.cycle)
                Text(lang.t("settings.signalLight.breathe")).tag(SignalLightEffectType.breathe)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                colorToggle(.red, label: lang.t("settings.signalLight.red"))
                colorToggle(.yellow, label: lang.t("settings.signalLight.yellow"))
                colorToggle(.green, label: lang.t("settings.signalLight.green"))

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

                Button(lang.t("settings.signalLight.test")) {
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
                    guard effect.colors.count > 1 else { return }
                    effect.colors.removeAll { $0 == color }
                }
            }
        ))
        .toggleStyle(.button)
    }
}
