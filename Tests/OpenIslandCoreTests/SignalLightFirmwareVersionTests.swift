import Testing
@testable import OpenIslandCore

struct SignalLightFirmwareVersionTests {
    @Test
    func parsesValidVersionStrings() {
        let version = SignalLightFirmwareVersion("1.2.3")
        #expect(version?.major == 1)
        #expect(version?.minor == 2)
        #expect(version?.patch == 3)
    }

    @Test
    func rejectsInvalidVersionStrings() {
        #expect(SignalLightFirmwareVersion("") == nil)
        #expect(SignalLightFirmwareVersion("1.2") == nil)
        #expect(SignalLightFirmwareVersion("1.2.3.4") == nil)
        #expect(SignalLightFirmwareVersion("1.2.x") == nil)
        #expect(SignalLightFirmwareVersion("v1.2.3") == nil)
    }

    @Test
    func comparesEqualVersionsAsEqual() {
        #expect(SignalLightFirmwareVersion("1.0.0") == SignalLightFirmwareVersion("1.0.0"))
    }

    @Test
    func comparesByPatchWhenMajorAndMinorMatch() {
        #expect(SignalLightFirmwareVersion("1.0.1")! > SignalLightFirmwareVersion("1.0.0")!)
    }

    @Test
    func comparesByMinorWhenMajorMatches() {
        #expect(SignalLightFirmwareVersion("1.1.0")! > SignalLightFirmwareVersion("1.0.9")!)
    }

    @Test
    func comparesByMajorFirst() {
        #expect(SignalLightFirmwareVersion("2.0.0")! > SignalLightFirmwareVersion("1.9.9")!)
    }
}
