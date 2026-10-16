import Foundation

/// How the signal light's LEDs behave for a given effect.
public enum SignalLightEffectType: String, Codable, Sendable, CaseIterable {
    case solid
    case blink
    case cycle
    case breathe
}

/// One of the signal light's three independently-addressable LEDs.
public enum SignalLightColor: String, Codable, Sendable, CaseIterable {
    case red
    case yellow
    case green

    var commandLetter: String {
        switch self {
        case .red: "R"
        case .yellow: "Y"
        case .green: "G"
        }
    }

    init?(commandLetter: Character) {
        switch commandLetter {
        case "R": self = .red
        case "Y": self = .yellow
        case "G": self = .green
        default: return nil
        }
    }
}

/// A fully-configurable light behavior: what type of animation, which
/// LEDs it involves (order matters for `.cycle`), and how fast.
public struct SignalLightEffect: Codable, Sendable, Equatable {
    public var type: SignalLightEffectType
    public var colors: [SignalLightColor]
    public var intervalMs: Int

    public init(type: SignalLightEffectType, colors: [SignalLightColor], intervalMs: Int) {
        self.type = type
        self.colors = colors
        self.intervalMs = intervalMs
    }
}

/// The four working-state buckets a single signal light can represent.
/// `idle` covers both "zero sessions" and "every session completed."
public enum SignalLightBucket: String, Codable, Sendable, CaseIterable, Hashable {
    case needsApproval
    case needsAnswer
    case running
    case idle
}

public extension SignalLightEffect {
    /// Sensible out-of-the-box behavior for each bucket, used to seed
    /// persisted settings on first run and as a fallback if a bucket is
    /// somehow missing from the user's configuration.
    static func defaultEffect(for bucket: SignalLightBucket) -> SignalLightEffect {
        switch bucket {
        case .idle:
            SignalLightEffect(type: .breathe, colors: [.green], intervalMs: 2000)
        case .running:
            SignalLightEffect(type: .blink, colors: [.yellow], intervalMs: 300)
        case .needsApproval:
            SignalLightEffect(type: .breathe, colors: [.yellow, .red], intervalMs: 1200)
        case .needsAnswer:
            SignalLightEffect(type: .breathe, colors: [.yellow, .green], intervalMs: 1200)
        }
    }
}

/// Resolves which single bucket a physical signal light should currently
/// display, given that multiple agent sessions may be in different phases
/// at once but there is only one light. Priority: anything needing manual
/// attention outranks anything merely running, which outranks idle.
public enum SignalLightBucketResolver {
    public static func resolve(_ state: SessionState) -> SignalLightBucket {
        let sessions = state.sessions

        if sessions.contains(where: { $0.phase == .waitingForApproval }) {
            return .needsApproval
        }
        if sessions.contains(where: { $0.phase == .waitingForAnswer }) {
            return .needsAnswer
        }
        if sessions.contains(where: { $0.phase == .running }) {
            return .running
        }
        return .idle
    }
}

/// Encodes/decodes the generic `EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>` BLE
/// command understood by the signal light firmware (see `led/led.ino`).
/// Example: `EFFECT:CYCLE:RYG:200`.
public enum SignalLightCommandEncoder {
    public static func encode(_ effect: SignalLightEffect) -> String {
        let typeText = effect.type.rawValue.uppercased()
        let colorsText = effect.colors.map(\.commandLetter).joined()
        return "EFFECT:\(typeText):\(colorsText):\(effect.intervalMs)"
    }

    public static func decode(_ command: String) -> SignalLightEffect? {
        let parts = command.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "EFFECT" else {
            return nil
        }
        guard let type = SignalLightEffectType(rawValue: parts[1].lowercased()) else {
            return nil
        }

        var colors: [SignalLightColor] = []
        for character in parts[2] {
            guard let color = SignalLightColor(commandLetter: character) else {
                return nil
            }
            colors.append(color)
        }
        guard !colors.isEmpty else {
            return nil
        }
        guard let intervalMs = Int(parts[3]) else {
            return nil
        }

        return SignalLightEffect(type: type, colors: colors, intervalMs: intervalMs)
    }
}

/// Fire-and-forget maintenance commands sent to the signal light outside the
/// bucket-effect/`EFFECT:` protocol — pin calibration, renaming, brightness,
/// and the light switch. See `signal-light/led_esp32c3/led_esp32c3.ino`.
public enum SignalLightControlCommand {
    public static func pinTest(pin: Int, on: Bool) -> String {
        "PINTEST:\(pin):\(on ? 1 : 0)"
    }

    public static func setPin(color: SignalLightColor, pin: Int) -> String {
        "SETPIN:\(color.commandLetter):\(pin)"
    }

    public static func setName(_ name: String) -> String {
        "SETNAME:\(name)"
    }

    public static let getConfig = "GETCONFIG"

    public static func brightness(percent: Int) -> String {
        "BRIGHTNESS:\(percent)"
    }

    public static func setPolarity(activeHigh: Bool) -> String {
        "SETPOLARITY:\(activeHigh ? "HIGH" : "LOW")"
    }

    public static let off = "OFF"
}

/// The device's current pin mapping and BLE name, as reported by `GETCONFIG`.
public struct SignalLightDeviceConfig: Equatable, Sendable {
    public var pins: [SignalLightColor: Int]
    public var name: String
    public var activeHigh: Bool

    public init(pins: [SignalLightColor: Int], name: String, activeHigh: Bool = false) {
        self.pins = pins
        self.name = name
        self.activeHigh = activeHigh
    }
}

/// Parses the firmware's `CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2` status reply
/// (see `sendConfigStatus` in `led_esp32c3.ino`).
public enum SignalLightConfigDecoder {
    public static func decode(_ line: String) -> SignalLightDeviceConfig? {
        guard line.hasPrefix("CONFIG:") else {
            return nil
        }

        var pins: [SignalLightColor: Int] = [:]
        var name: String?
        var activeHigh = false

        for field in line.dropFirst("CONFIG:".count).split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])

            switch key {
            case "R": if let pin = Int(value) { pins[.red] = pin }
            case "Y": if let pin = Int(value) { pins[.yellow] = pin }
            case "G": if let pin = Int(value) { pins[.green] = pin }
            case "NAME": name = value
            case "POL": activeHigh = (value == "HIGH")
            default: break
            }
        }

        guard pins.count == 3, let name else {
            return nil
        }
        return SignalLightDeviceConfig(pins: pins, name: name, activeHigh: activeHigh)
    }
}
