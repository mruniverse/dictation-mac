import DictationCore
@testable import DictationMac
import XCTest

@MainActor
final class FirstSendWiringTests: XCTestCase {
    func testFirstSendInvalidatesLockedTargetBeforePresentingAndForwardsArguments() {
        let ax = FakeAccessibility()
        let pid: pid_t = 4242
        let app = FakeAXElement(pid: pid, role: .value("AXApplication"))
        let window = FakeAXElement(pid: pid, role: .value("AXWindow"))
        window.subrole = .value("AXStandardWindow")
        let field = FakeAXElement(pid: pid, role: .value("AXTextArea"))
        field.window = window
        field.selection = AccessibilityTextRange(location: 17, length: 0)
        app.focusedWindow = window
        app.focusedUIElement = field
        ax.focusedApp = app
        ax.frontmost = pid
        ax.identities[pid] = AccessibilityProcess(
            pid: pid, bundleIdentifier: "com.apple.TextEdit", launchDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let pilot = TextEditInsertionPilot(backend: ax)
        let controller = CaptureController(
            permission: MacFakePermission(), capture: MacFakeCapture(), scheduler: MacFakeScheduler()
        )
        pilot.attach(to: controller) {}
        pilot.toggle()
        let session = UUID()
        XCTAssertEqual(controller.start(proposing: session, deadline: .now.advanced(by: .seconds(25))), .accepted(session))
        let delegate = AppDelegate(insertionPilot: pilot)
        let expectedDuration: TimeInterval = 7.25
        let replies = ResponseBox()
        let expectedReply: @Sendable @MainActor (Bool) -> Void = { replies.values.append($0) }
        var forwardedDuration: TimeInterval?
        var forwardedReply: (@Sendable @MainActor (Bool) -> Void)?
        let confirmation = delegate.makeFirstSendConfirmation { duration, reply in
            XCTAssertNil(pilot.lockedProcessIdentifier, "deve liberar o destino antes do prompt")
            forwardedDuration = duration
            forwardedReply = reply
            return .finished
        }

        XCTAssertEqual(pilot.lockedProcessIdentifier, pid)
        let handle = confirmation(expectedDuration, expectedReply)

        XCTAssertNotNil(handle)
        XCTAssertEqual(forwardedDuration, expectedDuration)
        forwardedReply?(true)
        XCTAssertEqual(replies.values, [true])
    }
}

@MainActor
private final class ResponseBox { var values: [Bool] = [] }
