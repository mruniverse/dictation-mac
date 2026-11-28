import AVFoundation
import CoreAudio
import DictationCore
@testable import DictationMac
import XCTest

/// Stands in for AVAudioEngine: no engine is created and no device is opened. The tap runs only
/// when a test calls `emit`, from the test's thread, like a buffer arriving from the audio thread.
@MainActor
private final class FakeCaptureEngine: CaptureEngine {
    static let systemDefault: AudioDeviceID = 7

    let configurationChangeSender: AnyObject = NSObject()
    var hardwareFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var refusesSelection = false
    var readbackFails = false
    var startError: Error?
    /// Device the unit reports: the default until a selection is accepted; a test may swap it.
    var current: AudioDeviceID = systemDefault
    /// Runs inside `start`, after the unit is running.
    var onStart: (() -> Void)?
    /// Runs inside `stop`, after the unit stopped.
    var onStop: (() -> Void)?
    private(set) var log: [String] = []
    private(set) var isRunning = false
    private(set) var hasTap = false
    private var tap: AVAudioNodeTapBlock?

    func selectInputDevice(_ device: AudioDeviceID) -> Bool {
        log.append("select \(device)")
        guard !refusesSelection else { return false }
        current = device
        return true
    }

    func currentInputDevice() -> AudioDeviceID? {
        log.append("readback")
        return readbackFails ? nil : current
    }

    func installTap(_ block: @escaping AVAudioNodeTapBlock) {
        log.append("installTap")
        tap = block
        hasTap = true
    }

    func removeTap() {
        log.append("removeTap")
        hasTap = false
    }

    func start() throws {
        log.append("start")
        if let startError { throw startError }
        isRunning = true
        onStart?()
    }

    func stop() {
        log.append("stop")
        isRunning = false
        onStop?()
    }

    /// Calls the last installed tap even after removal, like a buffer already in flight.
    func emit(_ samples: [Float]) {
        guard let tap,
              let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: tapFormat.sampleRate))
    }
}

private struct GrantedPermission: MicrophonePermission {
    func requestAccess(_ completion: @escaping @Sendable @MainActor (Bool) -> Void) { completion(true) }
}

private struct IdleScheduler: Scheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) {}
}

private struct UncheckedSender: @unchecked Sendable {
    let object: AnyObject
}

/// Production `EngineAudioCapture` over a fake engine: chosen device confirmed before any PCM,
/// configuration changes handled outside the notification callback, stale engines ignored.
@MainActor
final class EngineAudioCaptureTests: XCTestCase {
    private static let chosenUID = "usb-mic"
    private static let chosenID: AudioDeviceID = 42

    private var engines: [FakeCaptureEngine] = []
    private var created = 0
    private var chunks: [AudioChunk] = []
    private var failures: [CaptureFailure] = []

    override func setUp() async throws {
        engines = []
        created = 0
        chunks = []
        failures = []
    }

    // MARK: Chosen device

    func testChosenDeviceConfirmedAfterStartDeliversPCM() throws {
        let engine = FakeCaptureEngine()
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])

        try start(capture)
        XCTAssertEqual(
            engine.log, ["select \(Self.chosenID)", "installTap", "start", "readback"],
            "the device is read back from the running unit before start returns"
        )
        engine.emit([0.25, -0.25])
        drainMainQueue()

        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(chunks, [AudioChunk(samples: [0.25, -0.25], sampleRate: 48_000)])
        XCTAssertEqual(failures, [])
    }

    func testChosenDeviceSwappedAtStartStopsWithoutDeliveringPCM() {
        let engine = FakeCaptureEngine()
        engine.onStart = { [unowned engine] in
            engine.current = FakeCaptureEngine.systemDefault
            engine.emit([0.5, 0.5])
            // Even if the main queue drains before start returns, nothing unconfirmed is delivered.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])

        XCTAssertThrowsError(try start(capture)) {
            XCTAssertEqual($0 as? CaptureFailure, .selectedDeviceUnavailable, "not normalized to engineFailure")
        }
        drainMainQueue()

        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(engine.hasTap)
        XCTAssertEqual(chunks, [], "audio from the default device never reaches the caller")
        XCTAssertEqual(failures, [])
    }

    func testUnreadableDeviceAtStartStopsWithoutDeliveringPCM() {
        let engine = FakeCaptureEngine()
        engine.readbackFails = true
        engine.onStart = { [unowned engine] in engine.emit([0.5, 0.5]) }
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])

        XCTAssertThrowsError(try start(capture)) {
            XCTAssertEqual($0 as? CaptureFailure, .selectedDeviceUnavailable)
        }
        drainMainQueue()

        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(engine.hasTap)
        XCTAssertEqual(chunks, [])
    }

    func testRefusedSelectionNeverStartsTheEngine() {
        let engine = FakeCaptureEngine()
        engine.refusesSelection = true
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])

        XCTAssertThrowsError(try start(capture)) {
            XCTAssertEqual($0 as? CaptureFailure, .selectedDeviceUnavailable)
        }
        XCTAssertFalse(engine.log.contains("start"))
        XCTAssertFalse(engine.hasTap)
    }

    func testUnknownChosenDeviceFailsBeforeCreatingAnEngine() {
        let capture = makeCapture(uid: "unplugged", engines: [FakeCaptureEngine()])

        XCTAssertThrowsError(try start(capture)) {
            XCTAssertEqual($0 as? CaptureFailure, .selectedDeviceUnavailable)
        }
        XCTAssertEqual(created, 0)
    }

    func testChosenDeviceSwappedMidSessionStopsBeforeDeliveringPCM() throws {
        let engine = FakeCaptureEngine()
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])
        try start(capture)

        engine.current = FakeCaptureEngine.systemDefault
        engine.emit([0.5, 0.5])
        drainMainQueue()

        XCTAssertEqual(chunks, [])
        XCTAssertEqual(failures, [.selectedDeviceUnavailable])
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(engine.hasTap)
    }

    /// The real controller keeps the chosen-device failure instead of recording from the default.
    func testControllerDiscardsWithTheChosenDeviceFailureWhenStartLandsElsewhere() {
        let engine = FakeCaptureEngine()
        engine.onStart = { [unowned engine] in
            engine.current = FakeCaptureEngine.systemDefault
            engine.emit(Array(repeating: 0.5, count: 48_000))
        }
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])
        let controller = CaptureController(permission: GrantedPermission(), capture: capture, scheduler: IdleScheduler())

        controller.start()
        drainMainQueue()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.capture(.selectedDeviceUnavailable), duration: 0))
        XCTAssertFalse(engine.isRunning)
    }

    // MARK: Default device

    func testDefaultDeviceIsNeitherSelectedNorReadBack() throws {
        let engine = FakeCaptureEngine()
        let capture = makeCapture(uid: nil, engines: [engine])

        try start(capture)
        engine.emit([0.25])
        drainMainQueue()

        XCTAssertEqual(engine.log, ["installTap", "start"])
        XCTAssertEqual(chunks, [AudioChunk(samples: [0.25], sampleRate: 48_000)])
    }

    func testMissingInputFormatReportsNoMicrophoneOrTheChosenOne() {
        for (uid, expected) in [(nil, CaptureFailure.noInputDevice), (Self.chosenUID, .selectedDeviceUnavailable)] {
            let engine = FakeCaptureEngine()
            engine.hardwareFormat = AVAudioFormat()
            let capture = makeCapture(uid: uid, engines: [engine])

            XCTAssertThrowsError(try start(capture), String(describing: uid)) {
                XCTAssertEqual($0 as? CaptureFailure, expected, String(describing: uid))
            }
            XCTAssertFalse(engine.log.contains("start"), String(describing: uid))
            XCTAssertFalse(engine.hasTap, String(describing: uid))
        }
    }

    func testTapFormatTheTapCannotReadFailsBeforeStart() throws {
        let unreadable = [
            try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)),
            try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)),
            AVAudioFormat(),
        ]
        for format in unreadable {
            let engine = FakeCaptureEngine()
            engine.tapFormat = format
            let capture = makeCapture(uid: nil, engines: [engine])

            XCTAssertThrowsError(try start(capture), format.description) {
                XCTAssertEqual($0 as? CaptureFailure, .engineFailure, format.description)
            }
            XCTAssertFalse(engine.log.contains("start"), format.description)
            XCTAssertFalse(engine.hasTap, format.description)
        }
    }

    func testTapCannotStartWithStaleHardwareRateOrChannelCount() throws {
        for (rate, channels) in [(16_000.0, AVAudioChannelCount(1)), (48_000.0, AVAudioChannelCount(2))] {
            let engine = FakeCaptureEngine()
            engine.hardwareFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
            let capture = makeCapture(uid: Self.chosenUID, engines: [engine])

            XCTAssertThrowsError(try start(capture)) { XCTAssertEqual($0 as? CaptureFailure, .engineFailure) }
            XCTAssertFalse(engine.log.contains("installTap"), "a stale format must be rejected before installing the tap")
            XCTAssertFalse(engine.isRunning)
        }
    }

    func testInterleavedMonoFloatTapFormatIsAccepted() throws {
        let engine = FakeCaptureEngine()
        engine.hardwareFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        engine.tapFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true)
        )
        let capture = makeCapture(uid: nil, engines: [engine])

        try start(capture)
        engine.emit([0.1])
        drainMainQueue()

        XCTAssertEqual(chunks, [AudioChunk(samples: [0.1], sampleRate: 44_100)])
    }

    // MARK: Configuration change and stale engines

    func testConfigurationChangeFailsOnlyAfterTheNotificationCallbackReturned() throws {
        let engine = FakeCaptureEngine()
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])
        try start(capture, stopOnFailure: true)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine.configurationChangeSender)

        XCTAssertEqual(failures, [], "no failure inside the notification callback")
        XCTAssertTrue(engine.isRunning, "no teardown inside the notification callback")
        drainMainQueue()
        XCTAssertEqual(failures, [.deviceChanged])
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(engine.hasTap)
    }

    func testConfigurationChangeFromTheEngineQueueDoesNotWaitForTheMainThread() throws {
        let engine = FakeCaptureEngine()
        let capture = makeCapture(uid: Self.chosenUID, engines: [engine])
        try start(capture, stopOnFailure: true)

        XCTAssertTrue(
            postFromEngineQueue(engine.configurationChangeSender),
            "the engine's queue must not block on the main thread, which may be tearing the engine down"
        )
        XCTAssertEqual(failures, [])
        drainMainQueue()
        XCTAssertEqual(failures, [.deviceChanged])
        XCTAssertFalse(engine.isRunning)
    }

    func testLateConfigurationChangeOfThePreviousEngineLeavesTheCurrentOneRunning() throws {
        let previous = FakeCaptureEngine()
        let current = FakeCaptureEngine()
        let capture = makeCapture(uid: Self.chosenUID, engines: [previous, current])
        var previousChunks: [AudioChunk] = []
        var previousFailures: [CaptureFailure] = []
        try capture.start(
            onChunk: { previousChunks.append($0) },
            onFailure: { [unowned capture] in
                previousFailures.append($0)
                capture.stop()
            }
        )

        // Both reach the engine's side before the stop; their main-thread hops run after the next start.
        _ = postFromEngineQueue(previous.configurationChangeSender)
        previous.emit([0.9])
        capture.stop()
        try start(capture, stopOnFailure: true)
        drainMainQueue()

        XCTAssertEqual(previousFailures, [])
        XCTAssertEqual(previousChunks, [])
        XCTAssertEqual(failures, [])
        XCTAssertTrue(current.isRunning, "a late event of the previous engine does not stop the current one")
        XCTAssertTrue(current.hasTap)
        XCTAssertEqual(chunks, [])
        current.emit([0.3])
        drainMainQueue()
        XCTAssertEqual(chunks, [AudioChunk(samples: [0.3], sampleRate: 48_000)])
    }

    func testPCMQueuedBeforeStopIsNotDelivered() throws {
        let engine = FakeCaptureEngine()
        // Even if teardown drains the main queue, the generation is already closed.
        engine.onStop = { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let capture = makeCapture(uid: nil, engines: [engine])
        try start(capture)

        engine.emit([0.4])
        capture.stop()
        drainMainQueue()

        XCTAssertEqual(chunks, [])
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(engine.hasTap)
    }

    // MARK: Helpers

    private func makeCapture(uid: String?, engines: [FakeCaptureEngine]) -> EngineAudioCapture {
        self.engines = engines
        return EngineAudioCapture(
            inputUID: { uid },
            deviceID: { $0 == Self.chosenUID ? Self.chosenID : nil },
            makeEngine: { [unowned self] in
                created += 1
                return self.engines.removeFirst()
            }
        )
    }

    /// `stopOnFailure` mirrors the controller, which stops the capture from inside `onFailure`.
    private func start(_ capture: EngineAudioCapture, stopOnFailure: Bool = false) throws {
        try capture.start(
            onChunk: { [unowned self] in chunks.append($0) },
            onFailure: { [unowned self, unowned capture] in
                failures.append($0)
                if stopOnFailure { capture.stop() }
            }
        )
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
    }

    /// Posts from another thread, as the engine's internal queue does. True when the post returned
    /// while the main thread was still blocked here, i.e. no observer made that queue wait for it.
    private func postFromEngineQueue(_ sender: AnyObject) -> Bool {
        let returned = DispatchSemaphore(value: 0)
        let box = UncheckedSender(object: sender)
        Thread.detachNewThread {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: box.object)
            returned.signal()
        }
        return returned.wait(timeout: .now() + 1) == .success
    }
}
