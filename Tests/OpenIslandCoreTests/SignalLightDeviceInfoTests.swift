import Testing
@testable import OpenIslandCore

struct SignalLightDeviceInfoTests {
    @Test
    func parsesJSONPayload() {
        let info = SignalLightDeviceInfo.parse(#"{"hardware":"esp32c3","version":"1.2.1"}"#)
        #expect(info.hardware == "esp32c3")
        #expect(info.version == "1.2.1")
    }

    @Test
    func parsesJSONPayloadForFutureHardware() {
        let info = SignalLightDeviceInfo.parse(#"{"hardware":"esp32s3","version":"2.0.0"}"#)
        #expect(info.hardware == "esp32s3")
        #expect(info.version == "2.0.0")
    }

    @Test
    func fallsBackToLegacyHardwareForBareVersion() {
        let info = SignalLightDeviceInfo.parse("1.2.0")
        #expect(info.hardware == SignalLightDeviceInfo.legacyHardware)
        #expect(info.hardware == "esp32c3")
        #expect(info.version == "1.2.0")
    }

    @Test
    func trimsWhitespaceFromBareVersion() {
        let info = SignalLightDeviceInfo.parse("  1.2.0\n")
        #expect(info.hardware == "esp32c3")
        #expect(info.version == "1.2.0")
    }

    @Test
    func fallsBackWhenHardwareKeyMissing() {
        // Missing the required `hardware` key → not a valid device-info object,
        // so the whole string is treated as a (here, unparseable) version and
        // hardware defaults to the legacy board.
        let info = SignalLightDeviceInfo.parse(#"{"version":"1.2.0"}"#)
        #expect(info.hardware == "esp32c3")
        #expect(info.version == #"{"version":"1.2.0"}"#)
    }

    @Test
    func fallsBackForMalformedJSON() {
        let info = SignalLightDeviceInfo.parse("{not json")
        #expect(info.hardware == "esp32c3")
        #expect(info.version == "{not json")
    }
}
