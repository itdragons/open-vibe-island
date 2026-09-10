import Testing
@testable import OpenIslandApp

@Suite(.serialized)
struct KeystrokeInjectorTests {
    @Test
    func defaultInjectorPostsCmdShiftRightBracketWithoutCrashing() {
        // We can't observe actual OS-level CGEvent delivery in a unit test,
        // but constructing and posting the event without throwing/crashing
        // covers the init-time correctness of the keycode and flags.
        let injector = DefaultKeystrokeInjector()
        injector.sendCmdShiftRightBracket()  // no XCTAssert — if this crashes the test fails
    }

    @Test
    func spyKeystrokerRecordsCalls() {
        let spy = KeystrokeInjectorSpy()
        spy.sendCmdShiftRightBracket()
        spy.sendCmdShiftRightBracket()
        #expect(spy.callCount == 2)
    }
}

final class KeystrokeInjectorSpy: KeystrokeInjector, @unchecked Sendable {
    var callCount = 0
    func sendCmdShiftRightBracket() {
        callCount += 1
    }
}
