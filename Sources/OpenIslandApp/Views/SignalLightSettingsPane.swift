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
