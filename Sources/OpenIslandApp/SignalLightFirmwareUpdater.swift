import Foundation
@preconcurrency import CoreBluetooth
import Observation

/// Progress/outcome of an in-flight (or just-finished) BLE firmware flash.
enum SignalLightFirmwareUpdateState: Equatable {
    case idle
    case transferring(sent: Int, total: Int)
    case finishing
    case succeeded
    case failed(String)
}

enum SignalLightFirmwareUpdateError: LocalizedError {
    case notReady
    case disconnected
    case timedOut
    case firmwareRejected(String)
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .notReady: "Signal light is not connected"
        case .disconnected: "Device disconnected"
        case .timedOut: "Device did not respond in time"
        case .firmwareRejected(let status): status
        case .unreadableFile: "Could not read the firmware file"
        }
    }
}

/// Drives a BLE OTA firmware flash over the signal light's existing
/// `OTA_CONTROL`/`OTA_DATA` characteristics (see `signal-light/led/led.ino`).
/// Owns only the transfer state machine; `SignalLightCoordinator` owns the
/// actual CoreBluetooth session and forwards it the delegate callbacks this
/// type needs.
@MainActor
@Observable
final class SignalLightFirmwareUpdater {
    private(set) var state: SignalLightFirmwareUpdateState = .idle

    @ObservationIgnored private var otaControlCharacteristic: CBCharacteristic?
    @ObservationIgnored private var otaDataCharacteristic: CBCharacteristic?
    @ObservationIgnored private var chunkSize = 180
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWrite: (continuation: CheckedContinuation<Void, Error>, timeoutTask: Task<Void, Never>)?
    @ObservationIgnored private var pendingStatus: (continuation: CheckedContinuation<String, Error>, timeoutTask: Task<Void, Never>)?

    /// Starts flashing `fileURL` to the peripheral. No-ops if a transfer is
    /// already in progress; safe to call again after `.succeeded`/`.failed`.
    func beginUpdate(
        fileURL: URL,
        peripheral: CBPeripheral,
        otaControlCharacteristic: CBCharacteristic,
        otaDataCharacteristic: CBCharacteristic
    ) {
        switch state {
        case .transferring, .finishing:
            return
        default:
            break
        }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            state = .failed(SignalLightFirmwareUpdateError.unreadableFile.errorDescription ?? "Could not read file")
            return
        }

        self.otaControlCharacteristic = otaControlCharacteristic
        self.otaDataCharacteristic = otaDataCharacteristic
        chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        state = .transferring(sent: 0, total: data.count)

        transferTask = Task { [weak self] in
            await self?.runTransfer(peripheral: peripheral, data: data)
        }
    }

    /// Immediately marks the update as failed without starting a transfer —
    /// used by the coordinator when a flash is requested while disconnected.
    func failImmediately(_ reason: String) {
        guard case .idle = state else { return }
        state = .failed(reason)
    }

    /// Resets a stale `.succeeded` state back to `.idle` — called by the
    /// coordinator whenever a device (re)connects, since a successful
    /// reconnect is the natural point where "the last flash succeeded"
    /// should stop being shown and normal operation (including a possible
    /// next flash) resumes. No-ops in every other state.
    func acknowledgeSuccess() {
        guard case .succeeded = state else { return }
        state = .idle
    }

    /// Best-effort abort: tells the firmware to abandon the OTA write and
    /// unblocks whatever the transfer loop is currently awaiting.
    func cancel() {
        guard transferTask != nil else { return }

        if let otaControlCharacteristic, let peripheral = otaControlCharacteristic.service?.peripheral {
            peripheral.writeValue(Data("OTA_ABORT".utf8), for: otaControlCharacteristic, type: .withResponse)
        }
        failPending(with: CancellationError())
        transferTask?.cancel()
    }

    /// Called by the coordinator when the peripheral disconnects
    /// unexpectedly (not the reboot-after-success case, which finishes the
    /// transfer task before the disconnect happens).
    func handleUnexpectedDisconnect() {
        guard transferTask != nil else { return }
        failPending(with: SignalLightFirmwareUpdateError.disconnected)
        transferTask?.cancel()
    }

    /// Forwarded from `SignalLightCoordinator.peripheral(_:didWriteValueFor:error:)`.
    func handleWriteResponse(for characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === otaControlCharacteristic || characteristic === otaDataCharacteristic else { return }
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        pending.timeoutTask.cancel()
        if let error {
            pending.continuation.resume(throwing: error)
        } else {
            pending.continuation.resume()
        }
    }

    /// Forwarded from `SignalLightCoordinator.peripheral(_:didUpdateValueFor:error:)`
    /// for the `OTA_CONTROL` characteristic — this is how the firmware reports
    /// `OTA_BEGIN`/`OTA_END` success or failure (see `setOtaStatus` in `led.ino`).
    func handleControlStatusUpdate(_ text: String) {
        guard let pending = pendingStatus else { return }
        pendingStatus = nil
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: text)
    }

    private func failPending(with error: Error) {
        if let pending = pendingWrite {
            pendingWrite = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        if let pending = pendingStatus {
            pendingStatus = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private func runTransfer(peripheral: CBPeripheral, data: Data) async {
        do {
            let beginStatus = try await sendControlCommandAndAwaitStatus(
                "OTA_BEGIN:\(data.count)",
                on: peripheral,
                timeoutSeconds: 10
            )
            guard beginStatus.uppercased().contains("OK") else {
                throw SignalLightFirmwareUpdateError.firmwareRejected(beginStatus)
            }

            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, data.count)
                try await writeChunkAndAwaitAck(data.subdata(in: offset..<end), on: peripheral)
                offset = end
                state = .transferring(sent: offset, total: data.count)
            }

            state = .finishing
            let endStatus = try await sendControlCommandAndAwaitStatus("OTA_END", on: peripheral, timeoutSeconds: 15)
            guard endStatus.uppercased().contains("OK") else {
                throw SignalLightFirmwareUpdateError.firmwareRejected(endStatus)
            }

            state = .succeeded
        } catch is CancellationError {
            state = .idle
        } catch let error as SignalLightFirmwareUpdateError {
            state = .failed(error.errorDescription ?? "Firmware update failed")
        } catch {
            state = .failed(error.localizedDescription)
        }

        reset()
    }

    private func writeChunkAndAwaitAck(_ chunk: Data, on peripheral: CBPeripheral) async throws {
        guard let otaDataCharacteristic else {
            throw SignalLightFirmwareUpdateError.notReady
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.timeoutPendingWrite()
            }
            pendingWrite = (continuation, timeoutTask)
            peripheral.writeValue(chunk, for: otaDataCharacteristic, type: .withResponse)
        }
    }

    private func sendControlCommandAndAwaitStatus(
        _ text: String,
        on peripheral: CBPeripheral,
        timeoutSeconds: UInt64
    ) async throws -> String {
        guard let otaControlCharacteristic else {
            throw SignalLightFirmwareUpdateError.notReady
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.timeoutPendingStatus()
            }
            pendingStatus = (continuation, timeoutTask)
            peripheral.writeValue(Data(text.utf8), for: otaControlCharacteristic, type: .withResponse)
        }
    }

    private func timeoutPendingWrite() {
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        pending.continuation.resume(throwing: SignalLightFirmwareUpdateError.timedOut)
    }

    private func timeoutPendingStatus() {
        guard let pending = pendingStatus else { return }
        pendingStatus = nil
        pending.continuation.resume(throwing: SignalLightFirmwareUpdateError.timedOut)
    }

    private func reset() {
        otaControlCharacteristic = nil
        otaDataCharacteristic = nil
        transferTask = nil
    }
}
