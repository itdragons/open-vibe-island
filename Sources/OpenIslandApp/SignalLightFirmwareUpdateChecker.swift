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

/// Outcome of loading the full changelog — independent of any connected
/// device, so it can be viewed at any time.
enum SignalLightFirmwareChangelogState: Equatable {
    case idle
    case loading
    case loaded([String])
    case failed(String)
}

private struct SignalLightFirmwareManifest: Decodable {
    let version: String
    let notes: String?
    let history: [String]?
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
    private static let manifestTimeoutSeconds: TimeInterval = 5
    private static let binaryTimeoutSeconds: TimeInterval = 15
    /// Connection establishment to raw.githubusercontent.com intermittently
    /// stalls to a full timeout on some networks (observed on both dataTask
    /// and downloadTask — not specific to either), then succeeds immediately
    /// on the very next attempt. A short per-attempt timeout plus a couple of
    /// retries turns that into a non-issue instead of a multi-minute hang.
    private static let maxAttempts = 3

    private(set) var state: SignalLightFirmwareUpdateCheckState = .idle
    private(set) var changelogState: SignalLightFirmwareChangelogState = .idle

    func checkForUpdates(currentVersion: String?) async {
        guard let currentVersion, let current = SignalLightFirmwareVersion(currentVersion) else {
            state = .failed("Current firmware version is unknown")
            return
        }

        state = .checking
        do {
            let manifest = try await fetchManifest()
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

    /// Loads the full version history for display — doesn't require a
    /// connected device or a prior `checkForUpdates` call.
    func loadChangelog() async {
        changelogState = .loading
        do {
            let manifest = try await fetchManifest()
            let latestEntry = "\(manifest.version): \(manifest.notes ?? "")"
            changelogState = .loaded([latestEntry] + (manifest.history ?? []))
        } catch {
            changelogState = .failed("Couldn't load changelog")
        }
    }

    private func fetchManifest() async throws -> SignalLightFirmwareManifest {
        let data = try await fetchWithRetry(url: Self.manifestURL, timeout: Self.manifestTimeoutSeconds, failure: .requestFailed)
        return try JSONDecoder().decode(SignalLightFirmwareManifest.self, from: data)
    }

    /// Downloads the latest binary to a fresh temporary file and returns its
    /// URL. Throws on any network failure; callers leave `state` untouched
    /// (still `.updateAvailable`) so the user can retry without re-checking.
    func downloadLatestBinary() async throws -> URL {
        let data = try await fetchWithRetry(url: Self.binaryURL, timeout: Self.binaryTimeoutSeconds, failure: .downloadFailed)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-firmware.bin")
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        return destination
    }

    /// Fetches `url` with a bounded per-attempt timeout, retrying up to
    /// `maxAttempts` times — see the note on `maxAttempts` for why. Non-200
    /// responses fail immediately without retrying, since a retry won't fix
    /// a real server-side problem.
    private func fetchWithRetry(
        url: URL,
        timeout: TimeInterval,
        failure: SignalLightFirmwareUpdateCheckError
    ) async throws -> Data {
        var lastError: Error = failure

        for attempt in 1...Self.maxAttempts {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw failure
                }
                return data
            } catch let error as SignalLightFirmwareUpdateCheckError {
                throw error
            } catch {
                lastError = error
                if attempt < Self.maxAttempts {
                    continue
                }
            }
        }

        throw lastError
    }
}

enum SignalLightFirmwareUpdateCheckError: LocalizedError {
    case requestFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed: "Couldn't reach the update server"
        case .downloadFailed: "Couldn't download the firmware file"
        }
    }
}
