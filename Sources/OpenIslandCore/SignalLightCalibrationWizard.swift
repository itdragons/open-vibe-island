import Foundation

/// What the user reports seeing after a candidate pin was lit during the
/// wiring-calibration wizard.
public enum SignalLightWizardObservation: Sendable {
    case red
    case yellow
    case green
    case nothing
}

/// Drives the "which physical GPIO is actually red/yellow/green" wizard as a
/// pure state machine: given a candidate pin list and a stream of user
/// observations, produces the pin mapping to send via `SETPIN`. Has no BLE
/// dependency — `SignalLightSettingsPane` drives the actual `PINTEST` writes
/// and feeds answers back in.
public struct SignalLightCalibrationWizard: Sendable, Equatable {
    /// ESP32-C3 Super Mini safe GPIO pins, matching the firmware's
    /// `SAFE_GPIO_PINS` allow-list in `config.h`.
    public static let defaultCandidatePins = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 21]

    public let candidatePins: [Int]
    public private(set) var currentIndex: Int
    public private(set) var mapping: [SignalLightColor: Int]
    public private(set) var isFinished: Bool

    public init(candidatePins: [Int]) {
        precondition(!candidatePins.isEmpty, "Calibration wizard needs at least one candidate pin")
        self.candidatePins = candidatePins
        self.currentIndex = 0
        self.mapping = [:]
        self.isFinished = false
    }

    /// The pin the wizard is currently asking the user about, or `nil` once finished.
    public var currentPin: Int? {
        guard !isFinished, currentIndex < candidatePins.count else {
            return nil
        }
        return candidatePins[currentIndex]
    }

    /// Colors not yet matched to a pin.
    public var unresolvedColors: [SignalLightColor] {
        SignalLightColor.allCases.filter { mapping[$0] == nil }
    }

    /// Records the user's answer for `currentPin` and advances to the next
    /// candidate. No-ops once the wizard has already finished.
    public mutating func recordObservation(_ observation: SignalLightWizardObservation) {
        guard let pin = currentPin else {
            return
        }

        switch observation {
        case .red where mapping[.red] == nil:
            mapping[.red] = pin
        case .yellow where mapping[.yellow] == nil:
            mapping[.yellow] = pin
        case .green where mapping[.green] == nil:
            mapping[.green] = pin
        default:
            break
        }

        currentIndex += 1
        if unresolvedColors.isEmpty || currentIndex >= candidatePins.count {
            isFinished = true
        }
    }

    /// Resets to the beginning, discarding all recorded answers ("redo").
    public mutating func reset() {
        currentIndex = 0
        mapping = [:]
        isFinished = false
    }
}
