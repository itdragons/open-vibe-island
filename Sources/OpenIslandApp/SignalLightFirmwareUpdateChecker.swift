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
    /// Filename of the binary to download, relative to the hardware's
    /// `firmware/` dir. Named per-version (e.g. `esp32c3-1.2.1.bin`) so each
    /// release has an immutable URL. Optional for forward/backward safety —
    /// a manifest without it falls back to the legacy fixed filename.
    let binary: String?
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
    // Both URLs are built per-hardware: `…/signal-light/{hardware}/firmware/…`,
    // where `{hardware}` is the ID the connected device reports over its INFO
    // characteristic. This lets a future board publish its own firmware under
    // its own ID with no app change.
    //
    // The manifest is fetched from raw.githubusercontent.com rather than
    // jsDelivr: jsDelivr's edge cache ignores query strings when computing
    // its cache key (verified — two requests differing only by a `?_=`
    // query param came back with identical `age`/`cf-cache-status: HIT`),
    // so a freshly published version can hide behind a stale edge copy for
    // up to `s-maxage=43200` (12h). raw.githubusercontent.com's Fastly cache
    // is short-lived (~5 min, per its `Expires` header) and the small JSON
    // manifest doesn't hit the stall issue below, so this bounds staleness
    // to a few minutes instead.
    private static func manifestURL(hardware: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/\(hardware)/firmware/version.json")!
    }
    // The binary stays on jsDelivr's GitHub CDN mirror: direct connections
    // to raw.githubusercontent.com reliably stall mid-transfer on some
    // networks (reproduced with curl --noproxy '*', consistently stuck at
    // ~40KB into the 647KB binary — a network-level block on that host, not
    // an app or timeout-tuning issue). jsDelivr's edge for the same
    // repo/branch/path was reliable across repeated tests. Its up-to-12h
    // edge-cache staleness is no longer a concern now that binaries are named
    // per-version (immutable URL): a new release lands at a brand-new path the
    // edge has never cached, so it can't serve a stale copy.
    private static func binaryURL(hardware: String, binary: String) -> URL {
        URL(string: "https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/\(hardware)/firmware/\(binary)")!
    }
    /// Binary filename used when a manifest omits `binary` — the legacy fixed
    /// name, kept only as a defensive fallback.
    private static let fallbackBinaryName = "signal-light.bin"
    private static let manifestTimeoutSeconds: TimeInterval = 5
    private static let binaryTimeoutSeconds: TimeInterval = 15
    /// Defense in depth against ordinary transient network hiccups — the
    /// mid-transfer block above is the reason a *host* switch was needed,
    /// but a short timeout + retry is still worth keeping for garden-variety
    /// flakiness on any host.
    private static let maxAttempts = 3

    private(set) var state: SignalLightFirmwareUpdateCheckState = .idle
    private(set) var changelogState: SignalLightFirmwareChangelogState = .idle

    /// The hardware + binary filename resolved by the last successful check
    /// that found an update, so `downloadLatestBinary()` fetches exactly the
    /// file the manifest named, from the same per-hardware path. Cleared on
    /// `reset()` and whenever a check finds no update.
    private var pendingDownload: (hardware: String, binary: String)?

    /// Clears a stale check result on disconnect — a reconnect may be to a
    /// different physical device with different firmware, so a prior
    /// `.upToDate`/`.updateAvailable` result can't be trusted to still apply.
    /// Leaves `changelogState` alone since the changelog isn't tied to any
    /// particular device's version.
    func reset() {
        state = .idle
        pendingDownload = nil
    }

    func checkForUpdates(hardware: String?, currentVersion: String?) async {
        guard let currentVersion, let current = SignalLightFirmwareVersion(currentVersion) else {
            state = .failed("Current firmware version is unknown")
            return
        }
        let hardware = hardware ?? SignalLightDeviceInfo.legacyHardware

        state = .checking
        do {
            let manifest = try await fetchManifest(hardware: hardware)
            guard let latest = SignalLightFirmwareVersion(manifest.version) else {
                state = .failed("Update information is malformed")
                return
            }

            if latest > current {
                pendingDownload = (hardware: hardware, binary: manifest.binary ?? Self.fallbackBinaryName)
                state = .updateAvailable(version: manifest.version, notes: manifest.notes)
            } else {
                pendingDownload = nil
                state = .upToDate
            }
        } catch {
            state = .failed("Couldn't connect to update server")
        }
    }

    /// Loads the full version history for display — doesn't require a
    /// connected device or a prior `checkForUpdates` call.
    func loadChangelog(hardware: String?) async {
        let hardware = hardware ?? SignalLightDeviceInfo.legacyHardware
        changelogState = .loading
        do {
            let manifest = try await fetchManifest(hardware: hardware)
            let latestEntry = "\(manifest.version): \(manifest.notes ?? "")"
            // `history` is maintained oldest-first in version.json (each release
            // appends the previous version's note to the end) — reverse it so the
            // full list stays newest-first, matching `latestEntry` being prepended.
            changelogState = .loaded([latestEntry] + (manifest.history ?? []).reversed())
        } catch {
            changelogState = .failed("Couldn't load changelog")
        }
    }

    private func fetchManifest(hardware: String) async throws -> SignalLightFirmwareManifest {
        let data = try await fetchWithRetry(url: Self.manifestURL(hardware: hardware), timeout: Self.manifestTimeoutSeconds, failure: .requestFailed)
        return try JSONDecoder().decode(SignalLightFirmwareManifest.self, from: data)
    }

    /// Downloads the latest binary to a fresh temporary file and returns its
    /// URL. Throws on any network failure; callers leave `state` untouched
    /// (still `.updateAvailable`) so the user can retry without re-checking.
    func downloadLatestBinary() async throws -> URL {
        guard let pendingDownload else {
            throw SignalLightFirmwareUpdateCheckError.downloadFailed
        }
        let url = Self.binaryURL(hardware: pendingDownload.hardware, binary: pendingDownload.binary)
        let data = try await fetchWithRetry(url: url, timeout: Self.binaryTimeoutSeconds, failure: .downloadFailed)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-firmware.bin")
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        return destination
    }

    /// Fetches `url` with a bounded per-attempt timeout, retrying up to
    /// `maxAttempts` times — see the note on `maxAttempts` for why. A 404 (or
    /// other unexpected 4xx) fails immediately without retrying, since a
    /// retry won't fix a real server-side problem; 429/5xx are treated as
    /// transient and retried, since raw.githubusercontent.com has been
    /// observed to return 429 briefly before succeeding on the very next
    /// attempt.
    private func fetchWithRetry(
        url: URL,
        timeout: TimeInterval,
        failure: SignalLightFirmwareUpdateCheckError
    ) async throws -> Data {
        // A query item that changes on every call keeps the local `URLCache`
        // from ever serving a previously-cached response for this URL,
        // regardless of the origin's `Cache-Control` header. Note this does
        // NOT bust jsDelivr's own edge cache — verified separately that it
        // ignores query strings for its cache key — so it only guards
        // against staleness introduced on the client side.
        let bustedURL = Self.appendingCacheBuster(to: url)
        var lastError: Error = failure

        for attempt in 1...Self.maxAttempts {
            do {
                var request = URLRequest(url: bustedURL)
                request.timeoutInterval = timeout
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { throw failure }
                if httpResponse.statusCode == 200 {
                    return data
                }
                if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                    throw SignalLightFirmwareTransientHTTPError()
                }
                throw failure
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

    private static func appendingCacheBuster(to url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "_", value: String(Date().timeIntervalSince1970))
        ]
        return components.url!
    }
}

/// A 429/5xx response — distinct from `SignalLightFirmwareUpdateCheckError`
/// so `fetchWithRetry` retries it instead of failing immediately.
private struct SignalLightFirmwareTransientHTTPError: Error {}

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
