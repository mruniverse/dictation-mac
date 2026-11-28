import CoreAudio
import DictationCore
@testable import DictationMac
import XCTest

/// CoreAudio adapter. The device walk is opt-in (`DICTATION_MAC_AUDIO_PROBE=1`) because it reads
/// the host's real devices; it only reads HAL properties and never creates an engine, so no device
/// is opened and no audio is captured.
@MainActor
final class CoreAudioInputDevicesTests: XCTestCase {
    /// Resolves the UID against the host's real HAL list (read-only) and must fail before any engine exists.
    func testUnknownChosenDeviceFailsInsteadOfFallingBackToTheDefault() {
        var enginesCreated = 0
        let capture = EngineAudioCapture(
            inputUID: { "dictation-mac-missing-\(UUID().uuidString)" },
            makeEngine: {
                enginesCreated += 1
                return SystemCaptureEngine()
            }
        )

        XCTAssertThrowsError(try capture.start(onChunk: { _ in }, onFailure: { _ in })) {
            XCTAssertEqual($0 as? CaptureFailure, .selectedDeviceUnavailable)
        }
        XCTAssertEqual(enginesCreated, 0)
    }

    func testEveryListedDeviceHasAnInputFormatWithoutOpeningIt() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DICTATION_MAC_AUDIO_PROBE"] == "1", "opt-in host probe")
        let catalog = CoreAudioInputDevices()
        let devices = catalog.inputDevices()
        try XCTSkipIf(devices.isEmpty, "host without input devices")
        XCTAssertNotNil(catalog.defaultInputDevice())
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count)

        for device in devices {
            let id = try XCTUnwrap(catalog.deviceID(forUID: device.uid), device.name)
            let channels = catalog.inputChannels(of: id)
            let rate = try XCTUnwrap(catalog.nominalSampleRate(of: id), device.name)
            XCTAssertGreaterThan(channels, 0, device.name)
            XCTAssertGreaterThan(rate, 0, device.name)
            XCTAssertNotNil(catalog.deviceID(forUID: device.uid), device.name)
        }
    }
}
