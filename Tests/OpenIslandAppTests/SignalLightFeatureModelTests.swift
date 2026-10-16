import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
struct SignalLightFeatureModelTests {
    @Test func preferencesSurviveFeatureRecreation() throws {
        let suite = "SignalLightFeatureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let feature = SignalLightFeatureModel(defaults: defaults)
        #expect(feature.signalLightBrightness == 100)
        #expect(feature.signalLightEnabled)
        feature.signalLightBrightness = 42
        feature.signalLightEnabled = false
        let effect = SignalLightEffect(type: .solid, colors: [.red], intervalMs: 500)
        feature.signalLightEffects[.idle] = effect
        let restored = SignalLightFeatureModel(defaults: defaults)
        #expect(restored.signalLightBrightness == 42)
        #expect(!restored.signalLightEnabled)
        #expect(restored.resolvedSignalLightEffect() == effect)
    }

    @Test func reconnectProvidersFollowSessionAndPreferenceChanges() throws {
        let suite = "SignalLightFeatureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let feature = SignalLightFeatureModel(defaults: defaults)
        let session = AgentSession(id: "test", title: "Test", tool: .codex,
                                   phase: .waitingForApproval, summary: "", updatedAt: .now)
        feature.updateSessionState(SessionState(sessions: [session]))
        #expect(feature.currentBucket == .needsApproval)
        #expect(feature.signalLight.currentEffectProvider?() == .defaultEffect(for: .needsApproval))
        feature.signalLightBrightness = 35
        #expect(feature.signalLight.currentBrightnessProvider?() == 35)
        feature.signalLightEnabled = false
        #expect(!feature.signalLight.isLightSwitchedOn)
        feature.signalLightEnabled = true
        #expect(feature.signalLight.isLightSwitchedOn)
        feature.updateSessionState(SessionState())
        #expect(feature.signalLight.currentEffectProvider?() == .defaultEffect(for: .idle))
    }

    @Test func corruptEffectsFallBackToDefaults() throws {
        let suite = "SignalLightFeatureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: "signalLight.effects")
        let feature = SignalLightFeatureModel(defaults: defaults)
        #expect(feature.signalLightEffects.count == SignalLightBucket.allCases.count)
        #expect(feature.resolvedSignalLightEffect() == .defaultEffect(for: .idle))
    }

}
