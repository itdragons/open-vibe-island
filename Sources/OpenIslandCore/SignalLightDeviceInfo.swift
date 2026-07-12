import Foundation

/// What a signal-light device reports over its `INFO` characteristic: which
/// hardware it is and what firmware it runs. New firmware sends a compact JSON
/// object (`{"hardware":"esp32c3","version":"1.2.1"}`); firmware predating the
/// hardware-ID field sends a bare version string, which `parse` treats as the
/// legacy board.
public struct SignalLightDeviceInfo: Codable, Sendable, Equatable {
    public let hardware: String
    public let version: String

    public init(hardware: String, version: String) {
        self.hardware = hardware
        self.version = version
    }

    /// The only board that existed before firmware began reporting a hardware
    /// ID — so a bare-version payload can only have come from an ESP32-C3.
    /// Also the default the app falls back to when no device is connected.
    public static let legacyHardware = "esp32c3"

    /// Parses an `INFO` characteristic payload. Falls back to a legacy-hardware
    /// device carrying the raw string as its version whenever the payload isn't
    /// the expected JSON object (old firmware, or anything malformed) — callers
    /// then validate the version separately via `SignalLightFirmwareVersion`.
    public static func parse(_ raw: String) -> SignalLightDeviceInfo {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SignalLightDeviceInfo.self, from: data),
           !decoded.hardware.isEmpty,
           !decoded.version.isEmpty {
            return decoded
        }
        return SignalLightDeviceInfo(hardware: legacyHardware, version: trimmed)
    }
}
