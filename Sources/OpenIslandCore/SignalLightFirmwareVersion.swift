import Foundation

/// A `major.minor.patch` firmware version string, as reported by the device's
/// `INFO` characteristic and published in the online firmware manifest's
/// `version.json`. Comparable so update checks are a simple `>` comparison.
public struct SignalLightFirmwareVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: SignalLightFirmwareVersion, rhs: SignalLightFirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
