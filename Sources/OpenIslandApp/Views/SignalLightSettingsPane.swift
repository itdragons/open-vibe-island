import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenIslandCore

struct SignalLightSettingsPane: View {
    @Bindable var model: AppModel

    @State private var selectedFirmwareURL: URL?
    @State private var isShowingFlashConfirmation = false
    @State private var renameText = ""
    @State private var isShowingRenameReconnectNotice = false
    @State private var wizard: SignalLightCalibrationWizard?
    @State private var isDeviceManagementExpanded = false

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
            lightSection
            deviceManagementSection
        }
        .formStyle(.grouped)
        .navigationTitle(lang.t("settings.tab.signalLight"))
        .onChange(of: model.signalLight.status) { _, newStatus in
            if case .connected = newStatus {
                isShowingRenameReconnectNotice = false
            }
        }
        .sheet(isPresented: Binding(
            get: { wizard != nil },
            set: { isPresented in if !isPresented { cancelCalibration() } }
        )) {
            if let wizard {
                calibrationWizardView(wizard)
            }
        }
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
                .disabled(isTransferring)
            default:
                discoveredDevicesList
                Button(lang.t("settings.signalLight.scan")) {
                    model.signalLight.startScan()
                }
            }
        }
    }

    @ViewBuilder
    private var renameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(lang.t("settings.signalLight.renamePlaceholder"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                Button(lang.t("settings.signalLight.rename")) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    model.signalLight.sendRaw(SignalLightControlCommand.setName(trimmed))
                    isShowingRenameReconnectNotice = true
                    renameText = ""
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isShowingRenameReconnectNotice {
                Text(lang.t("settings.signalLight.renameReconnecting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

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

    private func bucketTitle(_ bucket: SignalLightBucket) -> String {
        switch bucket {
        case .needsApproval: lang.t("settings.signalLight.bucket.needsApproval")
        case .needsAnswer: lang.t("settings.signalLight.bucket.needsAnswer")
        case .running: lang.t("settings.signalLight.bucket.running")
        case .idle: lang.t("settings.signalLight.bucket.idle")
        }
    }

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
        case .idle, .failed:
            if case .failed(let reason) = model.signalLight.firmwareUpdater.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.t("settings.signalLight.firmwareFailedPrefix") + reason)
                        .foregroundStyle(.red)
                    Text(lang.t("settings.signalLight.firmwareFailedReassurance"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    // MARK: Wiring Calibration

    private func beginCalibration() {
        let newWizard = SignalLightCalibrationWizard(candidatePins: SignalLightCalibrationWizard.defaultCandidatePins)
        model.signalLight.isCalibrating = true
        if let pin = newWizard.currentPin {
            model.signalLight.sendRaw(SignalLightControlCommand.pinTest(pin: pin, on: true))
        }
        wizard = newWizard
    }

    private func recordCalibrationObservation(_ observation: SignalLightWizardObservation) {
        guard var current = wizard else { return }
        if let pin = current.currentPin {
            model.signalLight.sendRaw(SignalLightControlCommand.pinTest(pin: pin, on: false))
        }
        current.recordObservation(observation)
        wizard = current

        if current.isFinished {
            applyCalibrationResult(current)
        } else if let nextPin = current.currentPin {
            model.signalLight.sendRaw(SignalLightControlCommand.pinTest(pin: nextPin, on: true))
        }
    }

    private func applyCalibrationResult(_ finished: SignalLightCalibrationWizard) {
        for (color, pin) in finished.mapping {
            model.signalLight.sendRaw(SignalLightControlCommand.setPin(color: color, pin: pin))
        }
        if finished.unresolvedColors.isEmpty {
            model.signalLight.send(SignalLightEffect(type: .cycle, colors: [.red, .yellow, .green], intervalMs: 200))
        }
    }

    private func closeCalibration() {
        model.signalLight.isCalibrating = false
        wizard = nil
        resyncLightSwitchState()
    }

    private func cancelCalibration() {
        model.signalLight.isCalibrating = false
        wizard = nil
        resyncLightSwitchState()
    }

    /// Restores the light to whatever it should be showing once calibration
    /// ends — the current bucket's effect if the light switch is on, or an
    /// explicit `OFF` if it's off. Without this, ending calibration while
    /// switched off would leave the last-tested PINTEST pin lit (or, before
    /// this fix, `closeCalibration` would ignore the switch entirely and
    /// turn the light back on).
    private func resyncLightSwitchState() {
        if model.signalLightEnabled {
            let bucket = SignalLightBucketResolver.resolve(model.state)
            model.signalLight.send(model.signalLightEffects[bucket] ?? .defaultEffect(for: bucket))
        } else {
            model.signalLight.sendRaw(SignalLightControlCommand.off)
        }
    }

    @ViewBuilder
    private func calibrationWizardView(_ wizard: SignalLightCalibrationWizard) -> some View {
        VStack(spacing: 16) {
            Text(lang.t("settings.signalLight.calibrateTitle"))
                .font(.headline)

            if let pin = wizard.currentPin {
                Text(lang.t("settings.signalLight.calibrateAsking"))
                    .font(.subheadline)
                Text("GPIO \(pin)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(lang.t("settings.signalLight.red")) { recordCalibrationObservation(.red) }
                    Button(lang.t("settings.signalLight.yellow")) { recordCalibrationObservation(.yellow) }
                    Button(lang.t("settings.signalLight.green")) { recordCalibrationObservation(.green) }
                    Button(lang.t("settings.signalLight.calibrateNothing")) { recordCalibrationObservation(.nothing) }
                }

                Button(lang.t("settings.general.cancel"), role: .cancel) {
                    cancelCalibration()
                }
            } else {
                if wizard.unresolvedColors.isEmpty {
                    Text(lang.t("settings.signalLight.calibrateSucceeded"))
                        .foregroundStyle(.green)
                } else {
                    Text(lang.t("settings.signalLight.calibrateNotFoundPrefix") + wizard.unresolvedColors.map(colorName).joined(separator: ", "))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button(lang.t("settings.signalLight.calibrateRedo")) {
                        beginCalibration()
                    }
                    Button(lang.t("settings.signalLight.calibrateDone")) {
                        closeCalibration()
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }

    private func colorName(_ color: SignalLightColor) -> String {
        switch color {
        case .red: lang.t("settings.signalLight.red")
        case .yellow: lang.t("settings.signalLight.yellow")
        case .green: lang.t("settings.signalLight.green")
        }
    }
}

private struct SignalLightModeRow: View {
    let title: String
    let lang: LanguageManager
    @Binding var effect: SignalLightEffect
    let isTestDisabled: Bool
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

            HStack(spacing: 10) {
                colorToggle(.red, label: lang.t("settings.signalLight.red"))
                    .layoutPriority(1)
                colorToggle(.yellow, label: lang.t("settings.signalLight.yellow"))
                    .layoutPriority(1)
                colorToggle(.green, label: lang.t("settings.signalLight.green"))
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if effect.type != .solid {
                    Stepper(
                        "\(effect.intervalMs) ms",
                        value: $effect.intervalMs,
                        in: 100...3000,
                        step: 100
                    )
                    .layoutPriority(0)
                }

                Button(lang.t("settings.signalLight.test")) {
                    onTest(effect)
                }
                .layoutPriority(1)
                .disabled(isTestDisabled)
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
