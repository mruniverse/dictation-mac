import DictationCore
import Foundation

#if !CARBON_HOTKEY_TESTS
import XCTest

@MainActor
final class PushToTalkTests: XCTestCase {
    func testPressProposesAnExplicitSessionAfterActivationAndObservedRelease() {
        let capture = PushToTalkCaptureFake()
        let subject = PushToTalk(capture: capture, scheduler: FakeScheduler(), maximumHold: 5)
        let registration = UUID()
        subject.activate(registration: registration)
        subject.receive(.released, registration: registration)

        subject.receive(.pressed, registration: registration)

        XCTAssertEqual(capture.proposals.count, 1)
        XCTAssertEqual(capture.sessionID, capture.proposals.first)
        XCTAssertEqual(capture.phase, .awaitingPermission)
    }
    func testReleaseCancelsPendingPermissionAndStopsOnlyOwnedRecording() {
        let capture = PushToTalkCaptureFake()
        let subject = PushToTalk(capture: capture, scheduler: FakeScheduler())
        let registration = UUID()
        subject.activate(registration: registration)
        subject.receive(.released, registration: registration)
        subject.receive(.pressed, registration: registration)
        let pending = capture.sessionID!

        subject.receive(.released, registration: registration)
        XCTAssertEqual(capture.cancellations, [pending])
        XCTAssertTrue(capture.stops.isEmpty)

        subject.receive(.pressed, registration: registration)
        capture.phase = .recording
        let recording = capture.sessionID!
        subject.receive(.released, registration: registration)
        subject.receive(.released, registration: registration)
        XCTAssertEqual(capture.stops, [recording])
        XCTAssertNotEqual(recording, pending)
    }

    func testWatchdogStartsAtPressAndDiscardsPendingOrRecordingWithoutStop() {
        for phase in [CaptureController.Phase.awaitingPermission, .recording] {
            let capture = PushToTalkCaptureFake()
            let scheduler = FakeScheduler()
            let subject = PushToTalk(capture: capture, scheduler: scheduler, maximumHold: 5)
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            subject.receive(.pressed, registration: registration)
            let id = capture.sessionID!
            scheduler.advance(by: 4)
            capture.phase = phase
            subject.receive(.pressed, registration: registration)
            scheduler.advance(by: 1)

            XCTAssertEqual(capture.cancellations, [id])
            XCTAssertTrue(capture.stops.isEmpty)
            XCTAssertTrue(subject.isPressed)
            XCTAssertFalse(subject.isArmed)
            subject.receive(.pressed, registration: registration)
            XCTAssertEqual(capture.proposals.count, 1)
            subject.receive(.released, registration: registration)
            subject.receive(.pressed, registration: registration)
            XCTAssertEqual(capture.proposals.count, 2)
        }
    }

    func testReleaseUsesMonotonicDeadlineEvenIfWatchdogWasNotDelivered() {
        for (elapsed, shouldStop) in [(4.99, true), (5.0, false), (5.01, false)] {
            let capture = PushToTalkCaptureFake()
            let scheduler = FakeScheduler()
            let clock = PushToTalkTestClock()
            let subject = PushToTalk(capture: capture, scheduler: scheduler, maximumHold: 5, now: { clock.now })
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            subject.receive(.pressed, registration: registration)
            guard let id = capture.sessionID else { return XCTFail("Expected an owned session") }
            capture.grant(session: id)
            // Advance only the monotonic time; the watchdog must remain queued.
            clock.now = clock.now.advanced(by: .seconds(elapsed))

            subject.receive(.released, registration: registration)
            XCTAssertEqual(capture.cancellations, shouldStop ? [] : [id])
            XCTAssertEqual(capture.stops, shouldStop ? [id] : [])
        }
    }

    func testInvalidationWhileSchedulingDoesNotStartCapture() {
        for expire in [false, true] {
            let capture = PushToTalkCaptureFake()
            let scheduler = ReentrantPushToTalkScheduler()
            let subject = PushToTalk(capture: capture, scheduler: scheduler)
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            scheduler.run = { [weak subject] action in
                if expire { action() } else { subject?.deactivate() }
            }

            subject.receive(.pressed, registration: registration)
            XCTAssertTrue(capture.proposals.isEmpty)
            XCTAssertTrue(capture.cancellations.isEmpty)
        }
    }

    func testOldWatchdogCannotCancelTheNextGestureOrManualSession() {
        let capture = PushToTalkCaptureFake()
        let scheduler = FakeScheduler()
        let subject = PushToTalk(capture: capture, scheduler: scheduler, maximumHold: 5)
        let registration = UUID()
        subject.activate(registration: registration)
        subject.receive(.released, registration: registration)
        subject.receive(.pressed, registration: registration)
        scheduler.advance(by: 2)
        subject.receive(.released, registration: registration)
        subject.receive(.pressed, registration: registration)
        let second = capture.sessionID
        scheduler.advance(by: 3)
        XCTAssertEqual(capture.sessionID, second)
        XCTAssertEqual(capture.cancellations.count, 1)
        capture.sessionID = UUID()
        capture.phase = .recording
        scheduler.advance(by: 2)
        XCTAssertEqual(capture.cancellations.count, 1)
        XCTAssertTrue(capture.stops.isEmpty)
    }

    func testDeactivationAndReconfigurationDiscardAndRequireFreshRelease() {
        for reconfigure in [false, true] {
            let capture = PushToTalkCaptureFake()
            let scheduler = FakeScheduler()
            let subject = PushToTalk(capture: capture, scheduler: scheduler, maximumHold: 5)
            let old = UUID()
            let next = UUID()
            subject.activate(registration: old)
            subject.receive(.released, registration: old)
            subject.receive(.pressed, registration: old)
            let id = capture.sessionID!
            if reconfigure { subject.activate(registration: next) }
            else { subject.deactivate() }
            XCTAssertEqual(capture.cancellations, [id])
            XCTAssertTrue(subject.isPressed)
            XCTAssertFalse(subject.isArmed)
            subject.receive(.released, registration: old)
            subject.receive(.pressed, registration: old)
            XCTAssertEqual(capture.proposals.count, 1)
            if !reconfigure { subject.activate(registration: next) }
            subject.receive(.pressed, registration: next)
            XCTAssertEqual(capture.proposals.count, 1)
            subject.receive(.released, registration: next)
            subject.receive(.pressed, registration: next)
            XCTAssertEqual(capture.proposals.count, 2)
            scheduler.advance(by: 5)
            XCTAssertEqual(capture.cancellations.count, 2)
        }
    }

    func testEndedOrProcessingSessionDoesNotRearmWhileHeld() {
        for phase in [CaptureController.Phase.idle, .processing] {
            let capture = PushToTalkCaptureFake()
            let subject = PushToTalk(capture: capture, scheduler: FakeScheduler())
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            subject.receive(.pressed, registration: registration)
            let id = capture.sessionID!
            capture.phase = phase
            if phase == .idle { capture.sessionID = nil }
            subject.captureChanged()
            XCTAssertFalse(subject.isArmed)
            XCTAssertTrue(subject.isPressed)
            XCTAssertEqual(capture.cancellations, phase == .processing ? [id] : [])
            capture.phase = .idle
            capture.sessionID = nil
            subject.receive(.pressed, registration: registration)
            XCTAssertEqual(capture.proposals.count, 1)
            subject.receive(.released, registration: registration)
            XCTAssertTrue(capture.stops.isEmpty)
        }
    }

    func testReentrantReleaseOrDisableBeforeStartReturnsCancelsAcceptedID() {
        for disable in [false, true] {
            let capture = PushToTalkCaptureFake()
            let subject = PushToTalk(capture: capture, scheduler: FakeScheduler())
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            capture.onStart = { _ in
                if disable { subject.deactivate() }
                else { subject.receive(.released, registration: registration) }
            }
            subject.receive(.pressed, registration: registration)
            XCTAssertEqual(capture.cancellations, capture.proposals)
            XCTAssertTrue(capture.stops.isEmpty)
            XCTAssertFalse(subject.isArmed)
        }
    }

    func testOlderReentrantStartCannotInvalidateTheNewGesturesWatchdog() {
        let capture = PushToTalkCaptureFake()
        let scheduler = FakeScheduler()
        let subject = PushToTalk(capture: capture, scheduler: scheduler, maximumHold: 5)
        let registration = UUID()
        subject.activate(registration: registration)
        subject.receive(.released, registration: registration)
        capture.onStart = { _ in
            capture.onStart = nil
            subject.receive(.released, registration: registration)
            capture.phase = .idle
            capture.sessionID = nil
            subject.receive(.pressed, registration: registration)
        }
        subject.receive(.pressed, registration: registration)
        XCTAssertEqual(capture.proposals.count, 2)
        let current = capture.sessionID!

        scheduler.advance(by: 5)

        XCTAssertEqual(capture.cancellations, [current])
        XCTAssertTrue(capture.stops.isEmpty)
        XCTAssertFalse(subject.isArmed)
    }

    func testRejectedOrDifferentAcceptedIDNeverClaimsTheVisibleSession() {
        for result in [PushToTalkStart.rejected, .accepted(UUID())] {
            let capture = PushToTalkCaptureFake()
            capture.answer = result
            let scheduler = FakeScheduler()
            let subject = PushToTalk(capture: capture, scheduler: scheduler, maximumHold: 5)
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            subject.receive(.pressed, registration: registration)
            capture.phase = .recording
            scheduler.advance(by: 5)
            subject.receive(.released, registration: registration)
            XCTAssertTrue(capture.cancellations.isEmpty)
            XCTAssertTrue(capture.stops.isEmpty)
        }
    }

    func testInvalidWatchdogCannotStartAnUnboundedSession() {
        for maximumHold in [0, -1, .infinity, .nan, 31, .greatestFiniteMagnitude] {
            let capture = PushToTalkCaptureFake()
            let subject = PushToTalk(capture: capture, scheduler: FakeScheduler(), maximumHold: maximumHold)
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            subject.receive(.pressed, registration: registration)
            XCTAssertTrue(capture.proposals.isEmpty)
        }
    }

    func testDeinitDiscardsOnlyOwnedSessionAndWatchdogDoesNotRetainSubject() {
        for replaced in [false, true] {
            let capture = PushToTalkCaptureFake()
            let scheduler = FakeScheduler()
            var subject: PushToTalk? = PushToTalk(capture: capture, scheduler: scheduler)
            weak let weakSubject = subject
            let registration = UUID()
            subject!.activate(registration: registration)
            subject!.receive(.released, registration: registration)
            subject!.receive(.pressed, registration: registration)
            let owned = capture.sessionID!
            if replaced { capture.sessionID = UUID() }
            subject = nil
            XCTAssertNil(weakSubject)
            XCTAssertEqual(capture.cancellations, replaced ? [] : [owned])
            scheduler.advance(by: 100)
            XCTAssertEqual(capture.cancellations, replaced ? [] : [owned])
            XCTAssertTrue(capture.stops.isEmpty)
        }
    }

    func testLateGrantCannotResurrectAReleasedExpiredOrSuspendedGesture() {
        for termination in 0..<3 {
            let capture = PushToTalkCaptureFake()
            let scheduler = FakeScheduler()
            let subject = PushToTalk(capture: capture, scheduler: scheduler, maximumHold: 5)
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            subject.receive(.pressed, registration: registration)
            let id = capture.sessionID!
            switch termination {
            case 0: subject.receive(.released, registration: registration)
            case 1: scheduler.advance(by: 5)
            default: subject.deactivate()
            }
            capture.grant(session: id)
            subject.captureChanged()
            XCTAssertEqual(capture.phase, .idle)
            XCTAssertNil(capture.sessionID)
            XCTAssertEqual(capture.cancellations, [id])
            XCTAssertTrue(capture.stops.isEmpty)
        }
    }

    func testInitiallyOffAndActivationRequiresARelease() {
        let capture = PushToTalkCaptureFake()
        let subject = PushToTalk(capture: capture, scheduler: FakeScheduler())
        let registration = UUID()
        subject.receive(.pressed, registration: registration)
        XCTAssertNil(subject.registration)
        subject.activate(registration: registration)
        subject.receive(.pressed, registration: registration)
        XCTAssertTrue(capture.proposals.isEmpty)
    }

    func testPressProposesTheMonotonicDeadlineOfTheGesture() {
        let capture = PushToTalkCaptureFake()
        let clock = PushToTalkTestClock()
        let subject = PushToTalk(capture: capture, scheduler: FakeScheduler(), maximumHold: 5, now: { clock.now })
        let registration = UUID()
        subject.activate(registration: registration)
        subject.receive(.released, registration: registration)
        let pressedAt = clock.now

        subject.receive(.pressed, registration: registration)

        XCTAssertEqual(capture.deadlines, [pressedAt.advanced(by: .seconds(5))])
    }

    func testBlockedPressStartsNothingAndTheNextPressNeedsAFreshRelease() {
        let capture = PushToTalkCaptureFake()
        let gate = PushToTalkBlock()
        gate.isBlocked = true
        let subject = PushToTalk(capture: capture, scheduler: FakeScheduler(), blocked: { gate.isBlocked })
        let registration = UUID()
        subject.activate(registration: registration)
        subject.receive(.released, registration: registration)

        subject.receive(.pressed, registration: registration)
        XCTAssertTrue(capture.proposals.isEmpty)
        XCTAssertTrue(subject.isPressed)
        XCTAssertFalse(subject.isArmed)
        gate.isBlocked = false
        subject.receive(.pressed, registration: registration)
        XCTAssertTrue(capture.proposals.isEmpty, "a repeat of the blocked press must not start")

        subject.receive(.released, registration: registration)
        XCTAssertTrue(subject.isArmed, "the release still reaches the latch")
        subject.receive(.pressed, registration: registration)
        XCTAssertEqual(capture.proposals.count, 1)
    }

    func testReleaseWhileBlockedDiscardsTheOwnedRecordingInsteadOfSubmitting() {
        let capture = PushToTalkCaptureFake()
        let gate = PushToTalkBlock()
        let subject = PushToTalk(capture: capture, scheduler: FakeScheduler(), blocked: { gate.isBlocked })
        let registration = UUID()
        subject.activate(registration: registration)
        subject.receive(.released, registration: registration)
        subject.receive(.pressed, registration: registration)
        let id = capture.sessionID!
        capture.grant(session: id)
        gate.isBlocked = true

        subject.receive(.released, registration: registration)

        XCTAssertEqual(capture.cancellations, [id])
        XCTAssertTrue(capture.stops.isEmpty)
        XCTAssertFalse(subject.isPressed)
        XCTAssertTrue(subject.isArmed, "the release still reaches the latch")
    }

    func testManualSessionAndChangedIDAreNeverStoppedOrCancelled() {
        for phase in [CaptureController.Phase.awaitingPermission, .recording, .processing] {
            let capture = PushToTalkCaptureFake()
            let subject = PushToTalk(capture: capture, scheduler: FakeScheduler())
            let registration = UUID()
            subject.activate(registration: registration)
            subject.receive(.released, registration: registration)
            capture.phase = phase
            capture.sessionID = UUID()
            subject.receive(.pressed, registration: registration)
            XCTAssertFalse(subject.isArmed)
            capture.phase = .idle
            capture.sessionID = nil
            subject.receive(.pressed, registration: registration)
            subject.receive(.released, registration: registration)
            XCTAssertTrue(capture.proposals.isEmpty)
            XCTAssertTrue(capture.stops.isEmpty)
            XCTAssertTrue(capture.cancellations.isEmpty)

            subject.receive(.pressed, registration: registration)
            capture.phase = .recording
            capture.sessionID = UUID()
            subject.receive(.released, registration: registration)
            XCTAssertTrue(capture.stops.isEmpty)
            XCTAssertTrue(capture.cancellations.isEmpty)
        }
    }
}

@MainActor
private final class PushToTalkTestClock {
    var now = ContinuousClock.now
}

@MainActor
private final class PushToTalkBlock {
    var isBlocked = false
}

@MainActor
private final class ReentrantPushToTalkScheduler: Scheduler {
    typealias Action = @Sendable @MainActor () -> Void
    var run: ((Action) -> Void)?

    func schedule(after delay: TimeInterval, _ action: @escaping Action) {
        run?(action)
    }
}

@MainActor
private final class PushToTalkCaptureFake: PushToTalkCapture {
    var phase: CaptureController.Phase = .idle
    var sessionID: UUID?
    var proposals: [UUID] = []
    var deadlines: [ContinuousClock.Instant] = []
    var stops: [UUID] = []
    var cancellations: [UUID] = []
    var answer: PushToTalkStart?
    var onStart: ((UUID) -> Void)?

    func start(proposing id: UUID, deadline: ContinuousClock.Instant) -> PushToTalkStart {
        proposals.append(id)
        deadlines.append(deadline)
        sessionID = answer.flatMap { if case let .accepted(other) = $0 { other } else { nil } } ?? id
        phase = .awaitingPermission
        onStart?(id)
        return answer ?? .accepted(id)
    }
    func stop(session id: UUID) {
        stops.append(id)
        if sessionID == id { phase = .processing }
    }
    func cancel(session id: UUID) {
        cancellations.append(id)
        if sessionID == id { sessionID = nil; phase = .idle }
    }
    func grant(session id: UUID) {
        if sessionID == id, phase == .awaitingPermission { phase = .recording }
    }
}

#else
import Carbon

// No registered shortcut, posted key event, microphone, network or permission change.
// Run after swift test (Package.swift intentionally has no app test dependency):
// bin=$(swift build --show-bin-path)
// swiftc -swift-version 6 -D CARBON_HOTKEY_TESTS -parse-as-library -I "$bin/Modules" \
//   "$bin/DictationCore.build/"*.swift.o Sources/DictationMac/CarbonHotKey.swift \
//   Tests/DictationCoreTests/PushToTalkTests.swift -o .build/carbon-hotkey-tests
// .build/carbon-hotkey-tests
@main
@MainActor
private enum CarbonHotKeyChecks {
    static var checks = 0
    static var failures = 0
    static func main() throws {
        let backend = HotKeyBackendFake()
        let adapter = CarbonHotKey(backend: backend)
        var events: [PushToTalkEvent] = []
        var generations: [UUID] = []
        let generation = try adapter.activate(chord: .controlShiftD) { event, id in events.append(event); generations.append(id) }
        expect(backend.operations == ["install", "register"], "install before exclusive registration")
        let event = CarbonHotKeyEvent(eventClass: UInt32(kEventClassKeyboard), kind: UInt32(kEventHotKeyPressed), signature: backend.signature, id: backend.id)
        expect(backend.deliver(event), "registered press is handled")
        expect(events == [.pressed], "registered press reaches receiver synchronously")
        expect(adapter.registration == generation, "activation exposes its generation")
        for field in 0..<4 {
            var foreign = event
            switch field {
            case 0: foreign.eventClass = 0
            case 1: foreign.kind = UInt32(kEventRawKeyDown)
            case 2: foreign.signature ^= 1
            default: foreign.id += 1
            }
            expect(!backend.deliver(foreign), "unrelated event field \(field) is not handled")
        }
        var released = event
        released.kind = UInt32(kEventHotKeyReleased)
        expect(backend.deliver(released), "registered release is handled")
        expect(events == [.pressed, .released], "press/release ordering is synchronous")
        expect(generations == [generation, generation], "receiver gets the exact accepted registration generation")
        adapter.deactivate()
        expect(backend.operations == ["install", "register", "unregister", "remove"], "teardown unregisters before removing handler")
        expect(!backend.deliver(event), "queued callback after teardown is ignored")
        let oldID = backend.id
        let next = try adapter.activate(chord: .controlShiftD) { event, _ in events.append(event) }
        let otherBackend = HotKeyBackendFake()
        let otherAdapter = CarbonHotKey(backend: otherBackend)
        try otherAdapter.activate(chord: .controlShiftD) { _, _ in }
        expect(otherBackend.id != backend.id, "simultaneous adapters cannot share a native ID/signature pair")
        otherAdapter.deactivate()
        expect(next != generation, "reconfiguration creates a fresh generation")
        expect(backend.id != oldID, "reconfiguration never reuses a native event ID")
        expect(!backend.deliver(event, handler: 0), "old handler generation is ignored")
        expect(!backend.deliver(event), "old ID through current handler is ignored")
        adapter.deactivate()
        let clean = backend.operations
        adapter.deactivate()
        expect(backend.operations == clean, "teardown is idempotent")
        try checkCleanup()
        try checkNativeBridge()
        try checkInvalidChordsAndNativeFailure()
        if failures > 0 { exit(1) }
        print("Carbon hotkey checks passed: \(checks) assertions")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }

    static func checkNativeBridge() throws {
        let calls = NativeHotKeyCallsFake()
        let adapter = CarbonHotKey(backend: NativeCarbonHotKeyBackend(calls: calls.api))
        expect(calls.operations.isEmpty, "native construction is off")
        var received: [PushToTalkEvent] = []
        try adapter.activate(chord: .controlShiftD) { event, _ in received.append(event) }
        expect(calls.operations == ["install", "register"], "native install/register bridge is exercised")
        expect(calls.types.map(\.eventClass) == [UInt32(kEventClassKeyboard), UInt32(kEventClassKeyboard)], "native handler subscribes only to keyboard hotkeys")
        expect(calls.types.map(\.eventKind) == [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)], "native handler subscribes only to press/release")
        expect(calls.options == UInt32(kEventHotKeyExclusive), "native registration is exclusive")
        expect(calls.chord == .controlShiftD, "configured chord reaches native registration unchanged")
        let pressed = try calls.event(kind: UInt32(kEventHotKeyPressed))
        let released = try calls.event(kind: UInt32(kEventHotKeyReleased))
        defer { ReleaseEvent(pressed); ReleaseEvent(released) }
        expect(calls.deliver(pressed) == noErr, "native press decoded and synchronously handled")
        expect(calls.deliver(released) == noErr, "native release decoded and synchronously handled")
        expect(received == [.pressed, .released], "native callback preserves order without Tasks")
        let malformed = try calls.event(kind: UInt32(kEventHotKeyPressed), includeID: false)
        let raw = try calls.event(kind: UInt32(kEventRawKeyDown))
        defer { ReleaseEvent(malformed); ReleaseEvent(raw) }
        expect(calls.deliver(malformed) == eventNotHandledErr, "native malformed parameter is rejected")
        expect(calls.deliver(raw) == eventNotHandledErr, "native raw keyboard event is rejected")
        adapter.deactivate()
        expect(calls.operations == ["install", "register", "unregister", "remove"], "native teardown ordering")
    }

    static func checkInvalidChordsAndNativeFailure() throws {
        let invalid: [CarbonHotKey.Chord] = [
            .init(keyCode: 128, modifiers: UInt32(controlKey)),
            .init(keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey)),
            .init(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: UInt32(controlKey)),
            .init(keyCode: UInt32(kVK_Shift), modifiers: UInt32(controlKey)),
            .init(keyCode: UInt32(kVK_ANSI_D), modifiers: 0),
            .init(keyCode: UInt32(kVK_ANSI_D), modifiers: .max),
        ]
        for chord in invalid {
            let calls = NativeHotKeyCallsFake()
            let adapter = CarbonHotKey(backend: NativeCarbonHotKeyBackend(calls: calls.api))
            do {
                try adapter.activate(chord: chord) { _, _ in }
                expect(false, "invalid chord cannot register")
            } catch {}
            expect(calls.operations.isEmpty && adapter.registration == nil, "invalid chord stays off before native installation")
        }
        let calls = NativeHotKeyCallsFake()
        calls.removeStatus = OSStatus(paramErr)
        let adapter = CarbonHotKey(backend: NativeCarbonHotKeyBackend(calls: calls.api))
        try adapter.activate(chord: .controlShiftD) { _, _ in expect(false, "detached receiver cannot fire") }
        let event = try calls.event(kind: UInt32(kEventHotKeyPressed))
        defer { ReleaseEvent(event) }
        adapter.deactivate()
        expect(calls.deliver(event) == eventNotHandledErr, "failed native removal retains only an inert callback")
        do {
            try adapter.activate(chord: .controlShiftD) { _, _ in }
            expect(false, "failed removal cannot be overwritten by a new registration")
        } catch {}
        calls.removeStatus = noErr
        adapter.deactivate()
        for install in [false, true] {
            for missingHandle in [false, true] {
                let calls = NativeHotKeyCallsFake()
                if install {
                    calls.returnsHandler = !missingHandle
                    calls.installStatus = missingHandle ? noErr : OSStatus(paramErr)
                } else {
                    calls.returnsKey = !missingHandle
                    calls.registerStatus = missingHandle ? noErr : OSStatus(eventHotKeyExistsErr)
                }
                let adapter = CarbonHotKey(backend: NativeCarbonHotKeyBackend(calls: calls.api))
                do {
                    try adapter.activate(chord: .controlShiftD) { _, _ in }
                    expect(false, "native failure or absent handle cannot activate")
                } catch {
                    if case let CarbonHotKey.Failure.native(status) = error {
                        expect(status != noErr, "native failure cannot report a successful OSStatus")
                        if !missingHandle { expect(status == (install ? OSStatus(paramErr) : OSStatus(eventHotKeyExistsErr)), "native conflict/status is preserved") }
                    }
                }
                expect(adapter.registration == nil, "native failure stays off")
                let expected = install
                    ? (missingHandle ? ["install"] : ["install", "remove"])
                    : (missingHandle ? ["install", "register", "remove"] : ["install", "register", "unregister", "remove"])
                expect(calls.operations == expected, "native partial-failure cleanup")
            }
        }
    }

    static func checkCleanup() throws {
        for failure in [HotKeyBackendFake.Failure.install, .register] {
            let backend = HotKeyBackendFake()
            backend.failure = failure
            let adapter = CarbonHotKey(backend: backend)
            do {
                try adapter.activate(chord: .controlShiftD) { _, _ in }
                expect(false, "partial failure must throw")
            } catch {
                expect((error as? HotKeyBackendFake.Failure) == failure, "original registration error is preserved")
            }
            expect(adapter.registration == nil, "failure leaves adapter off")
            expect(!backend.handlerLive && !backend.keyLive, "failure cleans partial native resources")
            expect(backend.operations == (failure == .install ? ["install", "remove"] : ["install", "register", "unregister", "remove"]), "partial cleanup order")
        }
        let backend = HotKeyBackendFake()
        var adapter: CarbonHotKey? = CarbonHotKey(backend: backend)
        weak let weakAdapter = adapter
        try adapter!.activate(chord: .controlShiftD) { _, _ in }
        try adapter!.activate(chord: .controlShiftD) { _, _ in }
        expect(backend.operations == ["install", "register", "unregister", "remove", "install", "register"], "reconfiguration tears down the old chord first")
        adapter = nil
        expect(weakAdapter == nil, "handler must not retain adapter")
        expect(!backend.handlerLive && !backend.keyLive, "deinit tears down native resources")
    }
}

@MainActor
private final class HotKeyBackendFake: CarbonHotKeyBackend {
    enum Failure: Error { case install, register }
    var failure: Failure?
    var handlerLive = false
    var keyLive = false
    var operations: [String] = []
    var signature: UInt32 = 0
    var id: UInt32 = 0
    var handlers: [@MainActor (CarbonHotKeyEvent) -> Bool] = []
    func install(_ handler: @escaping @MainActor (CarbonHotKeyEvent) -> Bool) throws {
        operations.append("install")
        handlers.append(handler)
        handlerLive = true
        if failure == .install { throw Failure.install }
    }
    func register(_ chord: CarbonHotKey.Chord, signature: UInt32, id: UInt32) throws {
        operations.append("register")
        self.signature = signature
        self.id = id
        keyLive = true
        if failure == .register { throw Failure.register }
    }
    func unregister() {
        if keyLive { operations.append("unregister"); keyLive = false }
    }
    func removeHandler() {
        if handlerLive { operations.append("remove"); handlerLive = false }
    }
    func deliver(_ event: CarbonHotKeyEvent, handler index: Int? = nil) -> Bool {
        (index.map { handlers[$0] } ?? handlers.last)?(event) ?? false
    }
}

@MainActor
private final class NativeHotKeyCallsFake {
    var operations: [String] = []
    var types: [EventTypeSpec] = []
    var options: UInt32?
    var chord: CarbonHotKey.Chord?
    var hotKeyID = EventHotKeyID()
    var removeStatus: OSStatus = noErr
    var installStatus: OSStatus = noErr
    var registerStatus: OSStatus = noErr
    var returnsHandler = true
    var returnsKey = true
    var handler: EventHandlerUPP?
    var context: UnsafeMutableRawPointer?
    var api: CarbonHotKeyCalls {
        CarbonHotKeyCalls(
            install: { types, handler, context, output in
                self.operations.append("install")
                self.types = types
                self.handler = handler
                self.context = context
                output = self.returnsHandler ? OpaquePointer(bitPattern: 1) : nil
                return self.installStatus
            },
            register: { key, modifiers, id, options, output in
                self.operations.append("register")
                self.chord = .init(keyCode: key, modifiers: modifiers)
                self.hotKeyID = id
                self.options = options
                output = self.returnsKey ? OpaquePointer(bitPattern: 2) : nil
                return self.registerStatus
            },
            unregister: { _ in self.operations.append("unregister"); return noErr },
            remove: { _ in self.operations.append("remove"); return self.removeStatus }
        )
    }
    func event(kind: UInt32, includeID: Bool = true) throws -> EventRef {
        var event: EventRef?
        guard CreateEvent(nil, UInt32(kEventClassKeyboard), kind, 0, 0, &event) == noErr, let event else {
            throw HotKeyBackendFake.Failure.install
        }
        if includeID {
            var id = hotKeyID
            guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr else {
                ReleaseEvent(event)
                throw HotKeyBackendFake.Failure.install
            }
        }
        return event
    }
    func deliver(_ event: EventRef) -> OSStatus { handler?(nil, event, context) ?? OSStatus(eventNotHandledErr) }
}

#endif
