import Foundation
import Observation
import OpenIslandCore

/// Owns signal-light preferences and session synchronization, keeping the host
/// AppModel limited to forwarding state changes.
@MainActor
@Observable
final class SignalLightFeatureModel {
    private static let signalLightEffectsDefaultsKey = "signalLight.effects"
    private static let signalLightBrightnessDefaultsKey = "signalLight.brightness"
    private static let signalLightEnabledDefaultsKey = "signalLight.enabled"

    let signalLight = SignalLightCoordinator()
    private let defaults: UserDefaults
    private var state = SessionState()
    @ObservationIgnored private var lastSentSignalLightBucket: SignalLightBucket?

    var currentBucket: SignalLightBucket { SignalLightBucketResolver.resolve(state) }

    var signalLightEffects: [SignalLightBucket: SignalLightEffect] {
        didSet {
            guard let data = try? JSONEncoder().encode(signalLightEffects) else {
                return
            }
            defaults.set(data, forKey: Self.signalLightEffectsDefaultsKey)

            // If the edit changed the effect for whichever bucket is
            // currently showing, push it immediately instead of waiting for
            // the next session-state transition — otherwise editing e.g.
            // idle's effect while already idle looks like it did nothing.
            let bucket = SignalLightBucketResolver.resolve(state)
            if signalLightEnabled, !signalLight.isCalibrating, signalLightEffects[bucket] != oldValue[bucket] {
                signalLight.send(signalLightEffects[bucket] ?? .defaultEffect(for: bucket))
            }
        }
    }

    var signalLightBrightness: Int {
        didSet {
            guard signalLightBrightness != oldValue else { return }
            defaults.set(signalLightBrightness, forKey: Self.signalLightBrightnessDefaultsKey)
            signalLight.sendRaw(SignalLightControlCommand.brightness(percent: signalLightBrightness))
        }
    }

    var signalLightEnabled: Bool {
        didSet {
            guard signalLightEnabled != oldValue else { return }
            defaults.set(signalLightEnabled, forKey: Self.signalLightEnabledDefaultsKey)
            signalLight.isLightSwitchedOn = signalLightEnabled
            if signalLightEnabled {
                signalLight.send(resolvedSignalLightEffect())
            } else {
                signalLight.sendRaw(SignalLightControlCommand.off)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        signalLightEffects = Self.loadSignalLightEffects(defaults: defaults)
        signalLightBrightness = Self.loadSignalLightBrightness(defaults: defaults)
        signalLightEnabled = Self.loadSignalLightEnabled(defaults: defaults)
        signalLight.currentEffectProvider = { [weak self] in
            self?.resolvedSignalLightEffect()
        }
        signalLight.currentBrightnessProvider = { [weak self] in
            self?.signalLightBrightness
        }
        signalLight.isLightSwitchedOn = signalLightEnabled
    }

    func updateSessionState(_ state: SessionState) {
        self.state = state
        let bucket = SignalLightBucketResolver.resolve(state)
        if bucket != lastSentSignalLightBucket {
            lastSentSignalLightBucket = bucket
            if signalLightEnabled && !signalLight.isCalibrating {
                signalLight.send(resolvedSignalLightEffect())
            }
        }
    }

    private static func loadSignalLightEffects(defaults: UserDefaults) -> [SignalLightBucket: SignalLightEffect] {
        if let data = defaults.data(forKey: signalLightEffectsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SignalLightBucket: SignalLightEffect].self, from: data) {
            return decoded
        }
        return Dictionary(uniqueKeysWithValues: SignalLightBucket.allCases.map { ($0, .defaultEffect(for: $0)) })
    }

    private static func loadSignalLightBrightness(defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: signalLightBrightnessDefaultsKey) != nil else {
            return 100
        }
        return defaults.integer(forKey: signalLightBrightnessDefaultsKey)
    }

    private static func loadSignalLightEnabled(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: signalLightEnabledDefaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: signalLightEnabledDefaultsKey)
    }

    func resolvedSignalLightEffect() -> SignalLightEffect {
        let bucket = SignalLightBucketResolver.resolve(state)
        return signalLightEffects[bucket] ?? .defaultEffect(for: bucket)
    }
}
