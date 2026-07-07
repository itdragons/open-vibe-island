import Foundation
import Observation
import OpenIslandCore

/// Outcome of checking (or having checked) whether a newer signal-light
/// firmware version is published.
enum SignalLightFirmwareUpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, notes: String?)
    case failed(String)
}

private struct SignalLightFirmwareManifest: Decodable {
    let version: String
    let notes: String?
}

/// Checks a fixed pair of URLs on the `wg` branch of the signal-light's
/// GitHub fork for a newer firmware version, and downloads the binary when
/// the user chooses to update. Deliberately separate from
/// `SignalLightFirmwareUpdater`, which owns the actual BLE flash — this type
/// only ever produces a local file URL that gets handed to the existing
/// `SignalLightCoordinator.beginFirmwareUpdate(fileURL:)` flow unchanged.
@MainActor
@Observable
final class SignalLightFirmwareUpdateChecker {
    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/firmware/version.json")!
    private static let binaryURL = URL(string: "https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/firmware/signal-light.bin")!

    private(set) var state: SignalLightFirmwareUpdateCheckState = .idle

    func checkForUpdates(currentVersion: String?) async {
        guard let currentVersion, let current = SignalLightFirmwareVersion(currentVersion) else {
            state = .failed("Current firmware version is unknown")
            return
        }

        state = .checking
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.manifestURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                state = .failed("Couldn't connect to update server")
                return
            }
            let manifest = try JSONDecoder().decode(SignalLightFirmwareManifest.self, from: data)
            guard let latest = SignalLightFirmwareVersion(manifest.version) else {
                state = .failed("Update information is malformed")
                return
            }

            state = latest > current
                ? .updateAvailable(version: manifest.version, notes: manifest.notes)
                : .upToDate
        } catch {
            state = .failed("Couldn't connect to update server")
        }
    }

    /// Downloads the latest binary to a fresh temporary file and returns its
    /// URL. Throws on any network failure; callers leave `state` untouched
    /// (still `.updateAvailable`) so the user can retry without re-checking.
    func downloadLatestBinary() async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: Self.binaryURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SignalLightFirmwareUpdateCheckError.downloadFailed
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-firmware.bin")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}

enum SignalLightFirmwareUpdateCheckError: LocalizedError {
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed: "Couldn't download the firmware file"
        }
    }
}
