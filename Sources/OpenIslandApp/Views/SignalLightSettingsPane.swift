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
    @State private var lightSwitchWasOnBeforeCalibration = false
    @State private var isDeviceManagementExpanded = false
    @State private var testTimeoutTask: Task<Void, Never>?
    @State private var expandedSignalLightBucket: SignalLightBucket?
    @State private var testPreview: SignalLightTestPreview?
    @State private var isDownloadingFirmwareUpdate = false
    @State private var firmwareDownloadErrorMessage: String?
    @State private var isShowingChangelog = false
    @State private var isShowingUpdateAvailableAlert = false
    @State private var pendingUpdateVersion: String?
    @State private var pendingUpdateNotes: String?

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
        .sheet(isPresented: $isShowingChangelog) {
            changelogSheet
        }
        .onChange(of: model.signalLight.firmwareUpdateChecker.state) { _, newState in
            if case .updateAvailable(let version, let notes) = newState {
                pendingUpdateVersion = version
                pendingUpdateNotes = notes
                isShowingUpdateAvailableAlert = true
            }
        }
        .alert(
            lang.t("settings.signalLight.firmwareUpdateAvailableTitle"),
            isPresented: $isShowingUpdateAvailableAlert
        ) {
            Button(lang.t("settings.signalLight.downloadAndUpdate")) {
                downloadAndFlashLatestFirmware()
            }
            Button(lang.t("settings.general.cancel"), role: .cancel) {}
        } message: {
            let prefix = lang.t("settings.signalLight.firmwareUpdateAvailablePrefix") + (pendingUpdateVersion ?? "")
            if let pendingUpdateNotes, !pendingUpdateNotes.isEmpty {
                Text(prefix + "\n" + pendingUpdateNotes)
            } else {
                Text(prefix)
            }
        }
        .alert(
            lang.t("settings.signalLight.firmwareDownloadFailedTitle"),
            isPresented: Binding(
                get: { firmwareDownloadErrorMessage != nil },
                set: { isPresented in if !isPresented { firmwareDownloadErrorMessage = nil } }
            )
        ) {
            Button(lang.t("settings.general.cancel"), role: .cancel) {}
        } message: {
            Text(firmwareDownloadErrorMessage ?? "")
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
        .padding(.top, 6)
    }

    @ViewBuilder
    private var lightSection: some View {
        Section(lang.t("settings.signalLight.lightSection")) {
            Toggle(lang.t("settings.signalLight.lightSwitch"), isOn: $model.signalLightEnabled)

            HStack {
                Text(lang.t("settings.signalLight.lightBrightness"))
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
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }

            livePreviewRow

            ForEach(SignalLightBucket.allCases, id: \.self) { bucket in
                SignalLightModeRow(
                    title: bucketTitle(bucket),
                    lang: lang,
                    effect: Binding(
                        get: { model.signalLightEffects[bucket] ?? .defaultEffect(for: bucket) },
                        set: { model.signalLightEffects[bucket] = $0 }
                    ),
                    isExpanded: Binding(
                        get: { expandedSignalLightBucket == bucket },
                        set: { expandedSignalLightBucket = $0 ? bucket : nil }
                    ),
                    isTestDisabled: isTransferring,
                    onTest: { effect in
                        model.signalLight.send(effect)
                        testPreview = SignalLightTestPreview(bucket: bucket, effect: effect)
                        testTimeoutTask?.cancel()
                        testTimeoutTask = Task {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled else { return }
                            testPreview = nil
                            resyncLightSwitchState()
                        }
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

    private var isSignalLightConnected: Bool {
        if case .connected = model.signalLight.status { true } else { false }
    }

    @ViewBuilder
    private var livePreviewRow: some View {
        let bucket = testPreview?.bucket ?? SignalLightBucketResolver.resolve(model.state)
        let isNotConnected = testPreview == nil && !isSignalLightConnected
        let isOff = testPreview == nil && !model.signalLightEnabled
        let effect = testPreview?.effect
            ?? (isNotConnected || isOff ? SignalLightEffect(type: .solid, colors: [], intervalMs: 0)
                                         : (model.signalLightEffects[bucket] ?? .defaultEffect(for: bucket)))
        HStack(spacing: 12) {
            SignalLightPreviewPill(effect: effect)

            VStack(alignment: .leading, spacing: 2) {
                Text(lang.t("settings.signalLight.livePreview"))
                    .font(.system(size: 12, weight: .semibold))
                Text(previewCaption(bucket: bucket, effect: effect, isNotConnected: isNotConnected, isOff: isOff))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Not-connected takes priority over "light off" — even with the switch
    /// on, nothing reaches the physical device while it's disconnected, so
    /// that's the more fundamental reason the preview is blank.
    private func previewCaption(bucket: SignalLightBucket, effect: SignalLightEffect, isNotConnected: Bool, isOff: Bool) -> String {
        if isNotConnected {
            lang.t("settings.signalLight.notConnected")
        } else if isOff {
            lang.t("settings.signalLight.lightOff")
        } else {
            "\(bucketTitle(bucket)) · \(signalLightEffectSummary(effect, lang: lang))"
        }
    }

    // MARK: Device Management

    @ViewBuilder
    private var deviceManagementSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isDeviceManagementExpanded.toggle()
                } label: {
                    HStack {
                        Text(lang.t("settings.signalLight.deviceManagement"))
                        Spacer()
                        Image(systemName: isDeviceManagementExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isDeviceManagementExpanded {
                    Group {
                        if case .connected = model.signalLight.status {
                            VStack(alignment: .leading, spacing: 10) {
                                renameRow
                                Divider()
                                firmwareVersionRow
                                polarityRow
                                Divider()
                                firmwareRow
                                firmwareActionRow
                            }
                        } else {
                            Text(lang.t("settings.signalLight.firmwareNeedsConnection"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
    }

    private func presentChangelog() {
        isShowingChangelog = true
        Task {
            await model.signalLight.firmwareUpdateChecker.loadChangelog(hardware: model.signalLight.hardwareID)
        }
    }

    @ViewBuilder
    private var changelogSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.t("settings.signalLight.viewChangelog"))
                .font(.headline)

            switch model.signalLight.firmwareUpdateChecker.changelogState {
            case .idle, .loading:
                ProgressView()
            case .failed(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .loaded(let entries):
                if entries.isEmpty {
                    Text(lang.t("settings.signalLight.changelogEmpty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(entries, id: \.self) { entry in
                                Text(entry)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            Button(lang.t("settings.signalLight.close")) {
                isShowingChangelog = false
            }
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 220)
    }

    @ViewBuilder
    private var firmwareVersionRow: some View {
        HStack {
            Text(lang.t("settings.signalLight.firmwareVersion"))
            Button {
                presentChangelog()
            } label: {
                HStack(spacing: 3) {
                    Text(model.signalLight.firmwareVersion ?? lang.t("settings.signalLight.firmwareVersionUnknown"))
                    Image(systemName: "info.circle")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(lang.t("settings.signalLight.viewChangelog"))
            Spacer()
            Button(lang.t("settings.signalLight.calibrateWiring")) {
                beginCalibration()
            }
        }
    }

    @ViewBuilder
    private var polarityRow: some View {
        Picker(lang.t("settings.signalLight.polarity"), selection: Binding(
            get: { model.signalLight.lastDeviceConfig?.activeHigh ?? false },
            set: { newValue in
                model.signalLight.setLastKnownPolarity(activeHigh: newValue)
                model.signalLight.sendRaw(SignalLightControlCommand.setPolarity(activeHigh: newValue))
                model.signalLight.sendRaw(SignalLightControlCommand.getConfig)
            }
        )) {
            Text(lang.t("settings.signalLight.polarityLow")).tag(false)
            Text(lang.t("settings.signalLight.polarityHigh")).tag(true)
        }
        .disabled(isTransferring || model.signalLight.isCalibrating)
    }

    /// Combines "check for updates" and "pick a local file to flash" into one
    /// row — they're two ways of getting to the same OTA flash flow below,
    /// so they don't need a row each. A found update surfaces via an alert
    /// (see `body`'s `.onChange`/`.alert`) rather than inline text here.
    @ViewBuilder
    private var firmwareRow: some View {
        HStack {
            checkForUpdatesControl

            Spacer()

            if let selectedFirmwareURL {
                Text(selectedFirmwareURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(lang.t("settings.signalLight.firmwareChangeFile")) {
                    presentFirmwarePicker()
                }
                .disabled(isTransferring)
                Button(lang.t("settings.signalLight.firmwareFlash")) {
                    isShowingFlashConfirmation = true
                }
                .disabled(isTransferring)
                .confirmationDialog(
                    lang.t("settings.signalLight.firmwareConfirmTitle"),
                    isPresented: $isShowingFlashConfirmation
                ) {
                    Button(lang.t("settings.signalLight.firmwareConfirmAction"), role: .destructive) {
                        model.signalLight.beginFirmwareUpdate(fileURL: selectedFirmwareURL)
                    }
                    Button(lang.t("settings.general.cancel"), role: .cancel) {}
                } message: {
                    Text(lang.t("settings.signalLight.firmwareConfirmMessage"))
                }
            } else {
                Button(lang.t("settings.signalLight.firmwareChooseFile")) {
                    presentFirmwarePicker()
                }
                .disabled(isTransferring)
            }
        }
    }

    @ViewBuilder
    private var checkForUpdatesControl: some View {
        if isDownloadingFirmwareUpdate {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(lang.t("settings.signalLight.downloadingUpdate"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch model.signalLight.firmwareUpdateChecker.state {
            case .idle, .updateAvailable:
                Button(lang.t("settings.signalLight.checkForUpdates")) {
                    checkForFirmwareUpdates()
                }
                .disabled(isTransferring)

            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(lang.t("settings.signalLight.checkingForUpdates"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .upToDate:
                HStack(spacing: 4) {
                    Button(lang.t("settings.signalLight.checkForUpdates")) {
                        checkForFirmwareUpdates()
                    }
                    .disabled(isTransferring)
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .help(lang.t("settings.signalLight.firmwareUpToDate"))
                }

            case .failed(let reason):
                HStack(spacing: 4) {
                    Button(lang.t("settings.signalLight.checkForUpdates")) {
                        checkForFirmwareUpdates()
                    }
                    .disabled(isTransferring)
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .help(lang.t("settings.signalLight.firmwareCheckFailedPrefix") + reason)
                }
            }
        }
    }

    @ViewBuilder
    private var firmwareActionRow: some View {
        switch model.signalLight.firmwareUpdater.state {
        case .idle:
            EmptyView()

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("settings.signalLight.firmwareFailedPrefix") + reason)
                    .foregroundStyle(.red)
                Text(lang.t("settings.signalLight.firmwareFailedReassurance"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .transferring(let sent, let total, let bytesPerSecond):
            firmwareProgressRow(sent: sent, total: total, bytesPerSecond: bytesPerSecond)

        case .finishing:
            firmwareProgressRow(sent: nil, total: nil, bytesPerSecond: nil)

        case .succeeded:
            Text(lang.t("settings.signalLight.firmwareSucceeded"))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func firmwareProgressRow(sent: Int?, total: Int?, bytesPerSecond: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sent, let total, total > 0 {
                // The transfer stalls ~50-80ms every 32 chunks while the flow-
                // control barrier waits for the firmware to flush flash. Ease the
                // bar between updates so it glides across those stalls instead of
                // freezing then jumping.
                ProgressView(value: Double(sent), total: Double(total))
                    .animation(.linear(duration: 0.3), value: sent)
                // Percentage + running speed rather than a byte count: the speed
                // keeps moving, so the eye isn't drawn to the periodic stalls.
                HStack(spacing: 6) {
                    Text("\(Int(Double(sent) / Double(total) * 100))%")
                    if let bytesPerSecond, bytesPerSecond > 0 {
                        Text("·")
                        Text(formattedSpeed(bytesPerSecond))
                            .monospacedDigit()
                    }
                }
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

    private func checkForFirmwareUpdates() {
        firmwareDownloadErrorMessage = nil
        Task {
            await model.signalLight.firmwareUpdateChecker.checkForUpdates(hardware: model.signalLight.hardwareID, currentVersion: model.signalLight.firmwareVersion)
        }
    }

    private func downloadAndFlashLatestFirmware() {
        firmwareDownloadErrorMessage = nil
        isDownloadingFirmwareUpdate = true
        Task {
            defer { isDownloadingFirmwareUpdate = false }
            do {
                let fileURL = try await model.signalLight.firmwareUpdateChecker.downloadLatestBinary()
                selectedFirmwareURL = fileURL
                isShowingFlashConfirmation = true
            } catch {
                firmwareDownloadErrorMessage = error.localizedDescription
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

    private func formattedSpeed(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    // MARK: Wiring Calibration

    private func beginCalibration() {
        if !model.signalLight.isCalibrating {
            lightSwitchWasOnBeforeCalibration = model.signalLightEnabled
            model.signalLightEnabled = false
        }
        // Always clear the device before testing (including on "Redo") so a
        // leftover effect — the idle bucket's glow, or the previous run's
        // confirmation cycle — can't be mistaken for the pin under test.
        model.signalLight.sendRaw(SignalLightControlCommand.off)

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
            model.signalLight.send(SignalLightEffect(type: .cycle, colors: [.green, .yellow, .red], intervalMs: 200))
        }
    }

    private func closeCalibration() {
        model.signalLight.isCalibrating = false
        wizard = nil
        model.signalLightEnabled = lightSwitchWasOnBeforeCalibration
    }

    private func cancelCalibration() {
        model.signalLight.isCalibrating = false
        wizard = nil
        model.signalLightEnabled = lightSwitchWasOnBeforeCalibration
    }

    /// Restores the light to whatever it should be showing right now — the
    /// current bucket's effect if the light switch is on, or an explicit
    /// `OFF` if it's off. Used after a per-bucket test preview times out.
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
                    Button(lang.t("settings.signalLight.green")) { recordCalibrationObservation(.green) }
                    Button(lang.t("settings.signalLight.yellow")) { recordCalibrationObservation(.yellow) }
                    Button(lang.t("settings.signalLight.red")) { recordCalibrationObservation(.red) }
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

/// While a row's Test button is active, the live-preview strip shows that
/// effect instead of the resolved app-state bucket — mirroring what the
/// physical light is actually doing during the test window.
private struct SignalLightTestPreview {
    let bucket: SignalLightBucket
    let effect: SignalLightEffect
}

private func signalLightUIColor(for color: SignalLightColor) -> Color {
    switch color {
    case .red: return .red
    case .yellow: return .yellow
    case .green: return .green
    }
}

private func signalLightEffectSummary(_ effect: SignalLightEffect, lang: LanguageManager) -> String {
    let typeName: String
    switch effect.type {
    case .solid: typeName = lang.t("settings.signalLight.solid")
    case .blink: typeName = lang.t("settings.signalLight.blink")
    case .cycle: typeName = lang.t("settings.signalLight.cycle")
    case .breathe: typeName = lang.t("settings.signalLight.breathe")
    }
    guard effect.type != .solid else { return typeName }
    return "\(typeName) · \(effect.intervalMs)ms"
}

/// Animated preview of an effect's actual on-device behavior, used by the
/// live-preview strip. Blink/cycle/breathe redraw on a timer derived from
/// the effect's own interval so the pill's rhythm matches the real light.
private struct SignalLightPreviewPill: View {
    let effect: SignalLightEffect

    private var stepInterval: TimeInterval {
        max(0.05, Double(effect.intervalMs) / 1000)
    }

    var body: some View {
        switch effect.type {
        case .solid:
            pill(activeColors: effect.colors)
        case .blink:
            TimelineView(.periodic(from: .now, by: stepInterval)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / stepInterval)
                pill(activeColors: step.isMultiple(of: 2) ? effect.colors : [])
            }
        case .cycle:
            TimelineView(.periodic(from: .now, by: stepInterval)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / stepInterval)
                let active = effect.colors.isEmpty ? nil : effect.colors[step % effect.colors.count]
                pill(activeColors: active.map { [$0] } ?? [])
            }
        case .breathe:
            TimelineView(.animation) { context in
                let period = stepInterval
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let brightness = (sin(phase * 2 * .pi) + 1) / 2
                pill(activeColors: effect.colors, brightness: brightness)
            }
        }
    }

    private func pill(activeColors: [SignalLightColor], brightness: Double = 1) -> some View {
        HStack(spacing: 4) {
            ForEach([SignalLightColor.green, .yellow, .red], id: \.self) { color in
                Circle()
                    .fill(activeColors.contains(color) ? signalLightUIColor(for: color).opacity(brightness) : signalLightUIColor(for: color).opacity(0.15))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.75))
        .clipShape(Capsule())
    }
}

private struct SignalLightModeRow: View {
    let title: String
    let lang: LanguageManager
    @Binding var effect: SignalLightEffect
    @Binding var isExpanded: Bool
    let isTestDisabled: Bool
    let onTest: (SignalLightEffect) -> Void

    private var accentColors: [SignalLightColor] {
        [.green, .yellow, .red].filter(effect.colors.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow
            if isExpanded {
                expandedEditor
                    .padding(.bottom, 4)
            }
        }
    }

    private var summaryRow: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 2) {
                    ForEach(accentColors, id: \.self) { color in
                        Circle()
                            .fill(signalLightUIColor(for: color))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expandedEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(lang.t("settings.signalLight.effect"), selection: Binding(
                get: { effect.type },
                set: { newType in
                    effect.type = newType
                    if newType != .solid && effect.intervalMs == 0 {
                        switch newType {
                        case .cycle:
                            effect.intervalMs = 200
                        case .breathe:
                            effect.intervalMs = 1200
                        case .blink:
                            effect.intervalMs = 600
                        default:
                            effect.intervalMs = 600
                        }
                    }
                }
            )) {
                Text(lang.t("settings.signalLight.solid")).tag(SignalLightEffectType.solid)
                Text(lang.t("settings.signalLight.blink")).tag(SignalLightEffectType.blink)
                Text(lang.t("settings.signalLight.cycle")).tag(SignalLightEffectType.cycle)
                Text(lang.t("settings.signalLight.breathe")).tag(SignalLightEffectType.breathe)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    colorToggle(.green, label: lang.t("settings.signalLight.green"))
                    colorToggle(.yellow, label: lang.t("settings.signalLight.yellow"))
                    colorToggle(.red, label: lang.t("settings.signalLight.red"))
                }

                Spacer()

                if effect.type != .solid {
                    let intervalLabel = "\(effect.intervalMs) ms"
                    Stepper(
                        intervalLabel,
                        value: $effect.intervalMs,
                        in: 100...3000,
                        step: 100
                    )
                }

                Button(lang.t("settings.signalLight.test")) {
                    onTest(effect)
                }
                .disabled(isTestDisabled)
            }
        }
        .padding(.leading, 18)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func colorToggle(_ color: SignalLightColor, label: String) -> some View {
        let isSelected = effect.colors.contains(color)
        let action = {
            if isSelected {
                guard effect.colors.count > 1 else { return }
                effect.colors.removeAll { $0 == color }
            } else {
                guard !effect.colors.contains(color) else { return }
                effect.colors.append(color)
            }
        }

        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.black.opacity(0.75) : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? signalLightUIColor(for: color) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
