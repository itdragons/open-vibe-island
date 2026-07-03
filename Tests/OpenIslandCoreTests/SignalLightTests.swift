import Foundation
import Testing
@testable import OpenIslandCore

struct SignalLightBucketResolverTests {
    @Test
    func resolvesToNeedsApprovalWhenAnySessionIsWaitingForApproval() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .running),
            makeSession(id: "b", phase: .waitingForApproval),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .needsApproval)
    }

    @Test
    func resolvesToNeedsAnswerWhenNoApprovalButAnAnswerIsPending() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .completed),
            makeSession(id: "b", phase: .waitingForAnswer),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .needsAnswer)
    }

    @Test
    func resolvesToRunningWhenNoAttentionNeededButSomethingIsRunning() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .completed),
            makeSession(id: "b", phase: .running),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .running)
    }

    @Test
    func resolvesToIdleWhenAllSessionsAreCompleted() {
        let state = SessionState(sessions: [
            makeSession(id: "a", phase: .completed),
            makeSession(id: "b", phase: .completed),
        ])

        #expect(SignalLightBucketResolver.resolve(state) == .idle)
    }

    @Test
    func resolvesToIdleWhenThereAreNoSessions() {
        #expect(SignalLightBucketResolver.resolve(SessionState()) == .idle)
    }

    private func makeSession(id: String, phase: SessionPhase) -> AgentSession {
        AgentSession(
            id: id,
            title: "Test Session \(id)",
            tool: .codex,
            phase: phase,
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

struct SignalLightCommandEncoderTests {
    @Test
    func encodesSolidEffectWithSingleColor() {
        let effect = SignalLightEffect(type: .solid, colors: [.green], intervalMs: 0)
        #expect(SignalLightCommandEncoder.encode(effect) == "EFFECT:SOLID:G:0")
    }

    @Test
    func encodesCycleEffectWithOrderedColors() {
        let effect = SignalLightEffect(type: .cycle, colors: [.red, .yellow, .green], intervalMs: 200)
        #expect(SignalLightCommandEncoder.encode(effect) == "EFFECT:CYCLE:RYG:200")
    }

    @Test
    func decodeRoundTripsForEveryEffectType() {
        let effects: [SignalLightEffect] = [
            SignalLightEffect(type: .solid, colors: [.green], intervalMs: 0),
            SignalLightEffect(type: .blink, colors: [.yellow], intervalMs: 600),
            SignalLightEffect(type: .cycle, colors: [.red, .yellow, .green], intervalMs: 200),
            SignalLightEffect(type: .breathe, colors: [.red, .green], intervalMs: 2400),
        ]

        for effect in effects {
            let command = SignalLightCommandEncoder.encode(effect)
            #expect(SignalLightCommandEncoder.decode(command) == effect)
        }
    }

    @Test
    func decodeRejectsMalformedCommands() {
        #expect(SignalLightCommandEncoder.decode("EFFECT:SOLID:G") == nil)
        #expect(SignalLightCommandEncoder.decode("EFFECT:SPARKLE:G:0") == nil)
        #expect(SignalLightCommandEncoder.decode("EFFECT:SOLID:X:0") == nil)
        #expect(SignalLightCommandEncoder.decode("NOT_EFFECT:SOLID:G:0") == nil)
    }
}
