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

struct SignalLightControlCommandTests {
    @Test
    func encodesPinTestOn() {
        #expect(SignalLightControlCommand.pinTest(pin: 10, on: true) == "PINTEST:10:1")
    }

    @Test
    func encodesPinTestOff() {
        #expect(SignalLightControlCommand.pinTest(pin: 10, on: false) == "PINTEST:10:0")
    }

    @Test
    func encodesSetPin() {
        #expect(SignalLightControlCommand.setPin(color: .red, pin: 5) == "SETPIN:R:5")
    }

    @Test
    func encodesSetName() {
        #expect(SignalLightControlCommand.setName("MyOffice") == "SETNAME:MyOffice")
    }

    @Test
    func encodesBrightness() {
        #expect(SignalLightControlCommand.brightness(percent: 42) == "BRIGHTNESS:42")
    }

    @Test
    func exposesGetConfigAndOffAsFixedStrings() {
        #expect(SignalLightControlCommand.getConfig == "GETCONFIG")
        #expect(SignalLightControlCommand.off == "OFF")
    }
}

struct SignalLightConfigDecoderTests {
    @Test
    func decodesAWellFormedConfigLine() {
        let config = SignalLightConfigDecoder.decode("CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2")
        #expect(config == SignalLightDeviceConfig(pins: [.red: 5, .yellow: 6, .green: 7], name: "WG-A1B2"))
    }

    @Test
    func decodesRegardlessOfFieldOrder() {
        let config = SignalLightConfigDecoder.decode("CONFIG:NAME=WG-A1B2,G=7,R=5,Y=6")
        #expect(config == SignalLightDeviceConfig(pins: [.red: 5, .yellow: 6, .green: 7], name: "WG-A1B2"))
    }

    @Test
    func rejectsMissingPrefix() {
        #expect(SignalLightConfigDecoder.decode("R=5,Y=6,G=7,NAME=WG-A1B2") == nil)
    }

    @Test
    func rejectsMissingFields() {
        #expect(SignalLightConfigDecoder.decode("CONFIG:R=5,Y=6,NAME=WG-A1B2") == nil)
    }

    @Test
    func rejectsUnrelatedStatusText() {
        #expect(SignalLightConfigDecoder.decode("SETPIN ok: R=5") == nil)
    }
}
